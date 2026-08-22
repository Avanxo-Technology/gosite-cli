## 1. Fase 1 — Forms: identidad del cliente y anti-abuso

- [x] 1.1 Sustituir `clientIp()` en `src/addons/Forms/Helper/Forms.php` por una resolución basada en `forms.trustedProxies` (entero, default 0) que cuente saltos desde la derecha de `X-Forwarded-For` y caiga a `REMOTE_ADDR` cuando haya menos entradas que saltos
- [x] 1.2 Aceptar el `trustProxy` booleano antiguo como alias de `trustedProxies: 1`, emitiendo un aviso de obsolescencia
- [x] 1.3 Hacer que `memoryGet`/`memorySet` propaguen el fallo del backend en vez de tragarlo, y que `checkRateLimit` devuelva un estado distinguible de "límite superado"
- [x] 1.4 Devolver 503 con `Retry-After` cuando el rate limit no se puede evaluar, y saltar la consulta al backend por completo cuando `throttle` y `dailyLimit` son ambos 0
- [x] 1.5 Cambiar el default de `allowed_origins` para que la ausencia de configuración no emita `Access-Control-Allow-Origin`, conservando `['*']` como opt-in explícito
- [x] 1.6 Verificar que un POST del mismo origen sin cabecera `Origin` sigue procesándose con normalidad
- [x] 1.7 Actualizar `src/addons/Forms/README.md`: `trustedProxies`, semántica fail-closed, defaults de CORS
- [x] 1.8 Añadir el bloque `forms` con `trustedProxies: 1` al `cockpit/config.php` que genera `src/lib/templates.sh`

## 2. Fase 1 — Purga de caché fail-closed

- [x] 2.1 En el handler `PurgeCache` del template Go (`src/commands/cmd_create.sh`), devolver 503 cuando el entorno no es de desarrollo y no hay token configurado
- [x] 2.2 Sustituir la comparación de token por `subtle.ConstantTimeCompare`
- [x] 2.3 Emitir un warning al arrancar la app cuando un entorno no-dev carece de `COCKPIT_API_TOKEN`
- [x] 2.4 Registrar en `src/addons/CachePurge/bootstrap.php` el estado HTTP o el error de transporte de cada purga fallida, sin bloquear nunca el save de Cockpit
- [x] 2.5 Registrar una sola vez que la purga está desactivada cuando `APP_URL` está vacío
- [x] 2.6 Actualizar la documentación de despliegue generada para marcar `COCKPIT_API_TOKEN` como obligatorio en producción

## 3. Fase 1 — Superficie de red de la infraestructura

- [x] 3.1 Introducir `GOSITE_BIND_ADDRESS` (default `127.0.0.1`) en `src/lib/config.sh`
- [x] 3.2 Prefijar los puertos publicados de Mongo, Redis y MinIO con la dirección de bind en `src/commands/cmd_infra.sh`, dejando Traefik en todas las interfaces
- [x] 3.3 Avisar en `infra up` cuando el bind sea `0.0.0.0`, nombrando los servicios sin autenticación que quedan expuestos
- [x] 3.4 Generar credenciales aleatorias de MinIO en el primer `infra up` y persistirlas en el directorio de infra con modo 0600
- [x] 3.5 Detectar instalaciones con las credenciales `minioadmin` heredadas, seguir usándolas y explicar cómo rotarlas
- [x] 3.6 Propagar las credenciales generadas al `.env` de los proyectos en `create` y `sync`
- [x] 3.7 Eliminar `S3_VERIFY=false` de la plantilla de producción, conservándolo solo en la de desarrollo con su comentario
- [x] 3.8 Verificar que la comunicación entre contenedores por nombre de servicio sigue funcionando tras el cambio de bind

## 4. Fase 2 — Locking y atomicidad del estado

- [x] 4.1 Implementar `with_lock <archivo> <función>` en `src/lib/helpers.sh` sobre `mkdir`, con pid, `trap` de liberación y timeout acotado
- [x] 4.2 Reclamar locks huérfanos comprobando el pid con `kill -0` y la antigüedad, registrando la reclamación en modo verbose
- [x] 4.3 Hacer que toda escritura de estado use `mktemp` en el directorio de destino y publique con `mv`
- [x] 4.4 Envolver `registry_register` y `registry_forget` en `with_lock`
- [x] 4.5 Convertir `registry_entries` en una lectura pura que marque como no disponibles los directorios ausentes, sin reescribir el archivo
- [x] 4.6 Añadir `gosite list --prune` como el único camino que purga entradas obsoletas, bajo lock
- [x] 4.7 Fusionar `find_free_port` y `reserve_ports` en una sola operación bajo lock, para app y CMS a la vez
- [x] 4.8 Liberar la reserva de puertos cuando la creación falla después de haberlos reservado
- [x] 4.9 Corregir la expansión `${GOSITE_ARGS[@]:-}` en `src/main.sh` para que un array vacío no inyecte un argumento vacío

## 5. Fase 2 — Manifiesto e informe de deriva

- [x] 5.1 Definir el formato de `.gosite/manifest.tsv` (`ruta`, `sha256`, `versión de gosite`) y escribirlo desde `cmd_create`
- [x] 5.2 Generar el manifiesto a partir del contenido actual en la primera pasada de `sync` sobre un proyecto que no lo tenga, sin escribir ningún archivo del proyecto
- [x] 5.3 Implementar `gosite sync --report`: clasificar cada archivo gestionado como idéntico, derivado o ausente, sin escribir nada
- [x] 5.4 Implementar la comparación estructural del compose de producción con `yq`, clasificando claves añadidas, valores distintos y claves solo del proyecto
- [x] 5.5 Degradar a comparación textual normalizada cuando `yq` no esté presente, avisando de la menor precisión, y añadir `yq` como dependencia opcional en `doctor`
- [x] 5.6 Hacer que `--report` combinado con una bandera de estrictez salga con código distinto de cero cuando haya deriva

## 6. Fase 2 — Actualización segura de proyectos

- [x] 6.1 Excluir `docker-compose.prod.yml` de toda escritura en `_sync_compose` y en el sync por defecto
- [x] 6.2 Añadir `gosite sync --compose-prod --force` como única puerta de escritura, con copia previa `docker-compose.prod.yml.<timestamp>.bak` cuyo path se imprime
- [x] 6.3 Verificar que `--force` sin `--compose-prod` sigue sin escribir el compose de producción
- [x] 6.4 Comparar cada archivo gestionado con su hash del manifiesto antes de escribirlo: refrescar si coincide, conservar y reportar si difiere
- [x] 6.5 Restaurar desde el template los archivos gestionados que hayan desaparecido del proyecto
- [x] 6.6 Actualizar el manifiesto tras cada escritura de `sync`
- [x] 6.7 Actualizar el texto de ayuda de `sync` para que refleje la nueva garantía sobre el compose de producción

## 7. Fase 2 — Auditoría de defaults seguros

- [x] 7.1 Añadir a `gosite doctor` una sección de auditoría estrictamente de solo lectura sobre los proyectos registrados y la infraestructura
- [x] 7.2 Detectar `forms.trustedProxies` ausente, `COCKPIT_API_TOKEN` vacío y CORS abierto en cada proyecto
- [x] 7.3 Detectar Mongo o Redis publicados fuera de loopback en la infraestructura compartida
- [x] 7.4 Formatear cada hallazgo con proyecto, ajuste, valor observado, riesgo en una línea y comando de remediación
- [x] 7.5 Reportar como no disponibles los proyectos cuyo directorio falta, y continuar con el resto
- [x] 7.6 Salir con código distinto de cero cuando haya hallazgos y se pase la bandera de estrictez

## 8. Fase 2 — Integridad del auto-update

- [x] 8.1 Decidir y documentar dónde se publica el checksum de cada versión (resuelve una pregunta abierta del diseño)
- [x] 8.2 Verificar el digest del tarball descargado contra el checksum publicado antes de tocar la instalación
- [x] 8.3 Abortar cuando el checksum no esté disponible, explicando `--allow-unverified`, y avisar de forma prominente cuando se use esa bandera
- [x] 8.4 Dejar de leer `GOSITE_REPO` del entorno, reportar que se ignora, y añadir `--repo <owner>/<name>` como override explícito nombrado en la confirmación
- [x] 8.5 Preparar la nueva versión en un área de staging y respaldar la instalación previa antes de sustituirla
- [x] 8.6 Restaurar el respaldo cuando la sustitución falle a medias o cuando la versión nueva no ejecute `gosite version`
- [x] 8.7 Limpiar staging y respaldo tras un update correcto

## 9. Fase 3 — Puertas de calidad

- [x] 9.1 Ejecutar `shellcheck` sobre `src/**/*.sh`, contar los hallazgos y fijar la severidad de arranque (resuelve una pregunta abierta del diseño)
- [x] 9.2 Corregir o suprimir con justificación los hallazgos por encima de la severidad elegida
- [x] 9.3 Montar el workflow de CI con el job de lint
- [x] 9.4 Añadir el arnés de tests (bats) con `GOSITE_HOME` y `GOSITE_WORKSPACE` apuntando a directorios temporales y sin depender de Docker
- [x] 9.5 Cubrir con tests el registry, la reserva de puertos, el locking y la resolución de proyectos, incluyendo los casos de concurrencia de la Fase 2
- [x] 9.6 Añadir el job de smoke end-to-end `create → build → start → healthz`, con limpieza garantizada del proyecto, contenedores, volúmenes y red
- [x] 9.7 Alinear `.githooks/pre-commit` con un subconjunto rápido de las comprobaciones de CI, medir su duración y fijar el presupuesto (resuelve una pregunta abierta del diseño)

## 10. Fase 3 — Templates como archivos reales

- [x] 10.1 Diseñar el layout de `src/templates/` y el mecanismo de sustitución literal de `__PLACEHOLDER__`, sin `envsubst` ni `eval`
- [x] 10.2 Extraer los heredocs de Go de `cmd_create.sh` a archivos `.go` bajo el nuevo árbol
- [x] 10.3 Extraer los heredocs de compose, Dockerfile, `.air.toml` y configuración de Cockpit
- [x] 10.4 Extraer los heredocs de Markdown y `.env`
- [x] 10.5 Hacer que `create` y `sync` rendericen desde la misma fuente y produzcan resultados byte-idénticos para las mismas entradas
- [x] 10.6 Fallar la creación cuando un archivo renderizado conserve un token `__PLACEHOLDER__`, nombrando archivo y token
- [x] 10.7 Añadir el conjunto de valores de fixture y las comprobaciones `gofmt -l`, `go vet`, parseo de YAML y `php -l` sobre el render de fixture en CI
- [x] 10.8 Verificar la equivalencia byte a byte entre el generador viejo y el nuevo, salvo las correcciones intencionadas de Fases 1 y 2
- [x] 10.9 Retirar los heredocs una vez la equivalencia esté verificada

## 11. Fase 3 — Almacenamiento de submissions

- [x] 11.1 Sustituir el conteo por iteración de `Forms::forms()` por una agregación en base de datos
- [x] 11.2 Acotar y documentar en la interfaz el tamaño de muestra de `columnsFor()`
- [x] 11.3 Verificar que los formularios configurados sin submissions siguen apareciendo con conteo cero
- [x] 11.4 Añadir configuración de recogida y de periodo de retención de `ip` y `userAgent`, con un valor por defecto explícito y comentado en el scaffold (requiere la decisión de negocio abierta en el diseño)
- [x] 11.5 Implementar el camino de mantenimiento que limpia los campos personales de las submissions vencidas conservando el resto del documento
- [x] 11.6 Almacenar los campos personales vacíos cuando la recogida esté desactivada, manteniendo el rate limit operativo
- [x] 11.7 Reportar en la auditoría cuando la retención sea ilimitada

## 12. Cierre

- [x] 12.1 Bumpear `src/VERSION` en cada fase entregada, según exige el hook de pre-commit
- [x] 12.2 Redactar notas de versión que encabecen los cambios BREAKING de purga y de bind de red
- [x] 12.3 Actualizar `README.md` con `sync --report`, la garantía sobre el compose de producción y la auditoría de `doctor`
- [x] 12.4 Documentar como riesgos aceptados la API key de Replica y el `webhookSecret` de Forms almacenados en claro
