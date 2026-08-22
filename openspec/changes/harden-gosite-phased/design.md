## Context

gosite es tres productos en un repo: un CLI en Bash (~4k líneas), un generador de código que emite un monolito Go+Cockpit desde heredocs (`cmd_create.sh`, 2186 líneas), y una librería de addons PHP para Cockpit (~4k líneas). No hay tests, ni CI, ni linting; el único control automático es un hook de pre-commit que valida URLs de assets y el bump de `src/VERSION`.

Las restricciones que condicionan todo el diseño:

- **Bash 3.2 en macOS.** El objetivo primario es macOS, cuyo `/bin/bash` es 3.2 (sin arrays asociativos) y que **no trae `flock(1)`**. Cualquier locking debe funcionar ahí.
- **Hay proyectos vivos.** Existen sitios ya creados y desplegados con versiones anteriores. La migración no puede exigir recrear el proyecto.
- **`docker-compose.prod.yml` es territorio del equipo.** Es el archivo que la gente edita a mano (servicios extra, recursos, healthchecks). El usuario decidió explícitamente: gosite nunca lo escribe en un sync normal; reporta la deriva y el humano decide.
- **Defaults seguros para lo nuevo, opt-in explícito para lo existente.** `doctor` informa y jamás modifica; `sync` es el único camino que aplica, y solo cuando alguien lo invoca.
- **El código generado no se puede tocar retroactivamente.** Corregir `/cache/purge` cambia el binario Go; llega a un sitio existente solo cuando ese sitio re-scaffoldea y redespliega.

## Goals / Non-Goals

**Goals:**

- Cerrar los tres fallos-abiertos verificados en el repo (identidad de cliente en Forms, rate limit que se evapora si Redis cae, `/cache/purge` sin token) sin romper el flujo de desarrollo local.
- Hacer que el estado del CLI (`projects.tsv`, `ports.tsv`) resista concurrencia e interrupciones, en macOS.
- Dar un camino de actualización real a los proyectos existentes: addons y base sí, compose de producción no.
- Establecer el piso de calidad ausente: lint, tests de estado, smoke end-to-end.
- Que las tres fases sean entregables por separado, cada una con valor propio.

**Non-Goals:**

- Reescribir el CLI fuera de Bash.
- Cifrar en reposo la API key de Replica ni el `webhookSecret` de Forms. Riesgo aceptado y documentado.
- Un motor de merge YAML de tres vías. El informe de deriva describe; no fusiona.
- Migrar automáticamente sitios ya desplegados. Se les da un informe y un comando.
- Rediseñar la arquitectura de caché de la app Go (el `singleflight` + stale-while-revalidate actual es correcto).

## Decisions

### D1 — Confianza en el proxy: contar saltos desde la derecha, no un booleano

El `trustProxy` actual es un booleano que toma el **primer** elemento de `X-Forwarded-For` — exactamente el trozo que el cliente controla. Activarlo tal cual cambiaría un bug (bucket global) por otro (evasión trivial del rate limit rotando la cabecera).

La decisión es sustituirlo por `forms.trustedProxies`, un entero, y contar desde la derecha: con `N` proxies de confianza, la IP del cliente es el elemento en posición `len - N` de la lista. Todo lo que está a la izquierda es texto que el cliente pudo inventar y se descarta.

En la arquitectura de gosite `N = 1` siempre (un salto de Traefik), y ese es el valor que trae el scaffold. Si hay menos elementos que saltos de confianza, la configuración miente sobre la topología: se cae a `REMOTE_ADDR`, que es lo seguro.

*Alternativas descartadas:* (a) mantener el booleano y documentar el riesgo — deja una evasión conocida en un endpoint público; (b) lista de CIDR de proxies de confianza — más preciso y estándar, pero exige parseo de CIDR en PHP y conocer la subred de Docker, que cambia entre instalaciones; el conteo de saltos da el 95% del beneficio por el 10% del coste. `trustProxy` queda soportado como alias de `trustedProxies: 1` durante una versión, con aviso.

### D2 — Rate limit fail-closed con 503, no 429

Un fallo de Redis no es "demasiadas peticiones", es "no puedo decidir". Devolver 429 mentiría sobre la causa y confundiría al que integra el formulario. Se devuelve **503 con `Retry-After`**, que es reintentable y honesto.

Esto invierte el comentario actual del código (*"un corte de Redis no debe bloquear un lead real"*). El razonamiento nuevo: un corte de Redis con el límite desactivado significa que un bot puede inyectar submissions ilimitadas justo cuando el sistema está degradado, y la limpieza posterior cuesta más que los pocos leads perdidos durante el corte. El escape sigue existiendo: `throttle: 0` y `dailyLimit: 0` desactivan el límite explícitamente y entonces Redis ni se consulta, así que un sitio que prefiera disponibilidad puede elegirlo a conciencia.

### D3 — Locking portable con `mkdir`, no `flock`

`mkdir` es atómico en POSIX y está en todas partes; `flock(1)` no existe en macOS. Un directorio `<archivo>.lock` que contiene un `pid` sirve de lock: adquirir es `mkdir`, liberar es `rm -rf`, y un lock huérfano se detecta comprobando si el pid sigue vivo (`kill -0`) y por antigüedad.

Toda mutación pasa por un único helper `with_lock <archivo> <función>` que adquiere, ejecuta, y libera mediante `trap` incluso si la función falla. La publicación es `mktemp` en el mismo directorio del destino (no `$TMPDIR`, que puede estar en otro filesystem y romper la atomicidad de `mv`) seguido de `mv`.

*Alternativa descartada:* `flock` con fallback — dos rutas de código para el mismo invariante, y la ruta menos probada es justo la del entorno principal.

### D4 — Lectura del registry sin efectos colaterales

`registry_entries()` reescribe el archivo en cada lectura para autopurgarse. Eso convierte `gosite list` en un escritor, y una interrupción a mitad trunca el índice de proyectos.

Se separan las dos operaciones: leer es leer (los directorios ausentes se muestran como `unavailable`), y purgar es `gosite list --prune`, bajo lock. El autoconocimiento se pierde a cambio de que el índice sea indestructible; el coste es una línea de aviso en la salida de `list`.

### D5 — Un manifiesto por proyecto para distinguir "sin tocar" de "modificado a mano"

Sin saber qué escribió gosite la última vez, `sync` solo puede elegir entre pisar todo o no pisar nada. Se introduce `.gosite/manifest.tsv` en el proyecto: `<ruta>\t<sha256>\t<versión de gosite>` para cada archivo gestionado, escrito en cada `create` y `sync`.

La regla en `sync`: si el hash del archivo coincide con el del manifiesto, gosite escribió eso y nadie lo tocó → se refresca en silencio. Si difiere, hay trabajo humano dentro → se conserva y se reporta.

Los proyectos anteriores al manifiesto reciben uno **generado a partir de su contenido actual, sin escribir ningún archivo en esa primera pasada**. Es deliberadamente conservador: adopta el estado existente como base y a partir de ahí el mecanismo funciona con normalidad.

### D6 — El compose de producción se compara, nunca se fusiona

El informe de deriva necesita comparar YAML estructuralmente, no por líneas: el orden de claves y los comentarios no son deriva. Se usa `yq` cuando está disponible y, si no, el informe degrada a una comparación textual normalizada, avisando de la menor precisión. `yq` se declara dependencia **opcional**, comprobada por `doctor`.

Las tres clases del informe (`+` clave que el template añade, `~` valor que difiere, `!` clave solo del proyecto) son suficientes para que un humano decida, y no requieren resolver conflictos.

`--compose-prod --force` es la única puerta de escritura, y hace copia previa con marca temporal. Nunca borra la copia.

### D7 — `/cache/purge` 503 al arrancar, no 401 en la petición

Un token ausente es un error de despliegue, no de quien llama. El binario detecta al arrancar que está en un entorno no-dev sin token, lo registra como warning, y el endpoint responde 503. Un token presente pero incorrecto sigue siendo 401. La comparación pasa a ser `subtle.ConstantTimeCompare`.

Que sea **BREAKING** es el punto: hoy ese endpoint es público en cualquier sitio desplegado sin la variable. Romperlo de forma visible es preferible a dejarlo abierto en silencio.

### D8 — Los templates salen de los heredocs a `src/templates/`

Un árbol de archivos reales con extensión real, renderizado por sustitución de `__PLACEHOLDER__`. La sustitución se hace con un paso de reemplazo literal (no `envsubst`, que interpretaría `$` en el Go y el YAML; no `eval`, que ejecutaría backticks). El contenido del template es inerte por construcción.

Esto desbloquea `gofmt`, `go vet`, `php -l` y parseo de YAML sobre un render de fixture, que es la mitad del valor de la Fase 3. Se hace **al final**, no al principio: mover 1400 líneas antes de corregir los bugs mezclaría refactor con arreglo, y ningún test existiría todavía para validar la equivalencia.

La red de seguridad del movimiento: renderizar el árbol con el generador viejo y con el nuevo para el mismo proyecto y exigir que sean **byte-idénticos**, salvo las correcciones intencionadas de Fases 1 y 2.

### D9 — Fases por criticidad, no por área

Cada fase se puede entregar y liberar sola:

```
Fase 1  fallos abiertos          ─▶  cambia comportamiento en runtime
Fase 2  estado + migración       ─▶  cambia comportamiento del CLI
Fase 3  layout + CI + escala     ─▶  no cambia comportamiento
```

Fase 2 depende de Fase 1 solo en un punto: el informe de deriva y la auditoría necesitan saber cuáles son los defaults seguros, que Fase 1 define. Fase 3 depende de Fase 2 para el smoke test (necesita `create` estable). Dentro de cada fase las capacidades son independientes.

## Risks / Trade-offs

- **[El 503 del rate limit tumba formularios en un corte de Redis]** → `Retry-After` en la respuesta, mensaje reintentable, y la vía de escape documentada (`throttle: 0`) para quien prefiera disponibilidad sobre control de abuso. El comportamiento anterior queda accesible, pero como decisión consciente.
- **[El purge fail-closed rompe sitios desplegados sin token]** → Es intencional y está marcado BREAKING en la propuesta. Mitigación: `doctor` detecta la condición **antes** de actualizar y nombra la variable que falta; las notas de versión lo encabezan.
- **[Mover Mongo/Redis a loopback rompe herramientas del host]** → `GOSITE_BIND_ADDRESS` permite volver atrás explícitamente, con aviso al usar `0.0.0.0`. El caso común (Compass sobre `localhost`) sigue funcionando sin cambios.
- **[Lock por `mkdir` deja un lock huérfano si el proceso muere de forma violenta]** → El lock guarda su pid; se reclama si el proceso no existe o si supera el timeout. El peor caso es una espera acotada con un mensaje claro, no un bloqueo indefinido.
- **[El manifiesto de la primera pasada adopta como "de gosite" archivos que el usuario había modificado]** → Por eso la primera pasada no escribe nada. El usuario ve el informe de deriva antes de que nada se aplique, y a partir de ahí las modificaciones se detectan con normalidad.
- **[La migración de heredocs a templates introduce regresiones sutiles]** → Prueba de equivalencia byte a byte contra el generador viejo, y ejecutarla al final, cuando lint, tests de estado y smoke ya existen.
- **[Cuatro fases de trabajo sin entregar nada]** → Cada fase es liberable por sí sola; Fase 1 sola ya cierra los tres fallos abiertos.
- **[`yq` no está instalado]** → Dependencia opcional: el informe degrada a comparación textual y lo dice. Nada falla por su ausencia.

## Migration Plan

**Fase 1** — Se libera como versión menor con nota BREAKING. Un proyecto existente adopta los cambios de Forms al correr `gosite sync` (los addons son PHP, se refrescan en caliente); adopta el purge fail-closed al re-scaffoldear y redesplegar la app Go. La infraestructura adopta el binding de loopback en el siguiente `gosite infra up`, que recrea los contenedores.

**Fase 2** — `gosite sync --report` se libera antes que cualquier escritura, para que la gente pueda inspeccionar su deriva sin riesgo. El manifiesto se genera en la primera pasada sin escribir. `gosite update` gana la verificación de checksum en la misma versión que publica el checksum, de modo que la versión anterior pueda actualizarse a esta.

**Fase 3** — Sin impacto en proyectos existentes. La equivalencia de templates se valida antes de borrar los heredocs; los dos generadores conviven durante una versión.

**Rollback** — Fase 1 y 2 se revierten reinstalando la versión anterior del CLI; ningún cambio de esquema de datos es irreversible. La excepción es el binding de red de la infraestructura, que exige un `infra up` de la versión antigua para recrear los contenedores. Las copias `.bak` del compose de producción nunca se borran automáticamente.

## Open Questions

- **Severidad de `shellcheck`.** ¿Se arranca en `error` (limpio desde el día uno, poco valor) o en `warning` con una lista de excepciones que se va vaciando? Se resuelve al ver cuántos hallazgos produce la primera pasada sobre `src/`.
- **Dónde se publica el checksum de `gosite update`.** Un asset de GitHub Release es lo natural, pero hoy el update descarga el tarball de una rama, no de un release. Puede implicar adoptar releases etiquetados como el mecanismo de distribución.
- **Presupuesto de tiempo del pre-commit.** El spec exige que el hook sea rápido y coherente con CI; el número concreto se fija cuando se mida `shellcheck` sobre el repo completo.
- **Retención de PII por defecto.** El spec exige un valor explícito y documentado; cuál es (¿90 días?) es una decisión de negocio que corresponde al dueño del producto, no a este diseño.
