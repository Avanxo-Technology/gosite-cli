## Why

Una revisión de arquitectura sobre las ~10k líneas de `src/` encontró tres clases de debilidad que hoy no tienen red de seguridad: controles de seguridad que **fallan abiertos** en producción (rate limit de Forms inutilizado detrás de Traefik, `/cache/purge` sin token público si falta la variable, Mongo sin auth publicado en `0.0.0.0`), estado local del CLI que **se corrompe bajo concurrencia** (registry y reserva de puertos sin locking), y un generador de código sin **ningún** test, lint ni CI. Nada de esto es hipotético: son rutas de código leídas y verificadas en el repo.

El agravante es que gosite ya tiene proyectos creados en el mundo real. Corregir los templates no basta — hace falta un camino de actualización para los proyectos existentes que refresque addons y andamiaje base **sin reescribir `docker-compose.prod.yml`**, que es el archivo que los equipos editan a mano y donde un clobber silencioso cuesta un incidente.

## What Changes

El trabajo se agrupa en tres fases por criticidad. Cada fase es entregable e independiente.

### Fase 1 — Alto: fallos abiertos en el camino de producción

- Forms deja de confiar en `REMOTE_ADDR` detrás de un proxy: la identidad del cliente se resuelve contando saltos desde la derecha de `X-Forwarded-For`, con el número de proxies de confianza como configuración explícita. Hoy todo el tráfico comparte un único bucket de rate limit.
- El rate limit de Forms **falla cerrado**: si el backend de memoria (Redis) no responde, la petición se rechaza en vez de saltarse el límite.
- `Access-Control-Allow-Origin` deja de ser `*` por defecto en el receptor público de Forms.
- **BREAKING** `/cache/purge` en el Go generado falla cerrado: sin `COCKPIT_API_TOKEN` en un entorno no-dev el endpoint responde 503 en vez de quedar abierto.
- La infraestructura compartida publica Mongo, Redis y MinIO en `127.0.0.1` en vez de `0.0.0.0`, y las credenciales de MinIO dejan de ser `minioadmin/minioadmin` fijas.

### Fase 2 — Medio: integridad del estado y camino de actualización

- Registry (`projects.tsv`) y reserva de puertos (`ports.tsv`) pasan a ser transaccionales: un solo lock por archivo, escritura atómica, y la lectura deja de reescribir el archivo como efecto colateral.
- La selección y reserva de puerto se vuelve una operación única bajo lock, eliminando la carrera entre dos `gosite create` concurrentes.
- **Nuevo `gosite sync --report`**: informe de deriva entre el proyecto y los templates actuales, por archivo, sin escribir nada.
- **`docker-compose.prod.yml` pasa a ser de solo lectura para gosite.** Nunca se reescribe en un sync normal; la deriva se reporta y el humano decide. Solo un `--compose-prod --force` explícito lo sobrescribe, y con copia previa.
- Addons y andamiaje base sí se refrescan en proyectos existentes, con detección de modificaciones locales antes de escribir.
- **`gosite doctor` audita seguridad**: reporta cada desviación de los defaults seguros en los proyectos registrados (trustProxy ausente, token de purga vacío, CORS abierto) sin corregir nada por su cuenta.
- **BREAKING** `gosite update` verifica la integridad de lo que descarga (checksum publicado) y deja de aceptar el repositorio de origen desde el entorno.

### Fase 3 — Bajo: mantenibilidad y escala

- Los templates del proyecto generado (Go, YAML, Markdown) salen de los heredocs de `cmd_create.sh` a archivos reales bajo `src/templates/`, renderizados por sustitución de placeholders.
- Puertas de calidad en CI: `shellcheck` sobre `src/**/*.sh`, `gofmt`/`go vet` sobre los templates Go, `php -l` sobre los addons, y un smoke end-to-end `create → build → healthz`.
- Las consultas de Forms que hoy iteran hasta 10 000 documentos en PHP pasan a agregaciones; las submissions ganan política de retención para los campos PII (`ip`, `userAgent`).

### Reglas transversales de migración

- Los proyectos nuevos nacen con los defaults seguros.
- Los proyectos existentes **solo** cambian cuando alguien ejecuta `gosite sync` de forma explícita; `doctor` informa pero jamás modifica.
- Ningún paso de migración escribe `docker-compose.prod.yml` sin `--force`.

## Capabilities

### New Capabilities

Fase 1:
- `forms-abuse-controls`: identificación del cliente detrás de proxy, rate limit fail-closed y política de origen del receptor público de Forms.
- `cache-purge-auth`: autenticación fail-closed del endpoint de purga de caché en la app Go generada.
- `infra-network-exposure`: superficie de red y credenciales de la infraestructura compartida (Traefik, Redis, Mongo, MinIO).

Fase 2:
- `project-state-integrity`: atomicidad y locking del registry de proyectos y de la reserva de puertos.
- `project-template-sync`: actualización de proyectos existentes — informe de deriva, refresco de addons y base, e inmutabilidad de `docker-compose.prod.yml`.
- `secure-defaults-audit`: auditoría de configuración de seguridad en `gosite doctor`, en modo informe.
- `cli-self-update-integrity`: verificación de integridad y fijación del origen en `gosite update`.

Fase 3:
- `template-source-layout`: los templates del proyecto generado como archivos versionados en vez de heredocs.
- `quality-gates`: linting, verificación de templates y smoke test en CI y en el hook de pre-commit.
- `forms-submission-storage`: eficiencia de consulta y retención de datos personales en las submissions.

### Modified Capabilities

Ninguna. `openspec/specs/` está vacío; todas las capacidades de arriba son nuevas.

## Impact

**Código afectado**

| Área | Archivos |
| --- | --- |
| Forms | `src/addons/Forms/Helper/Forms.php`, `src/addons/Forms/Controller/Api.php`, `src/addons/Forms/README.md` |
| App Go generada | `src/commands/cmd_create.sh` (handlers, config), `src/lib/templates.sh` (`cockpit/config.php`, `.env`) |
| Infraestructura | `src/commands/cmd_infra.sh` |
| Estado del CLI | `src/lib/helpers.sh` (registry, puertos) |
| Actualización | `src/commands/cmd_sync.sh`, `src/commands/cmd_update.sh` |
| Calidad | `.githooks/pre-commit`, nuevo `.github/workflows/` |
| Reorganización | `src/commands/cmd_create.sh` → `src/templates/**` (Fase 3) |

**Rupturas y compatibilidad**

- Un sitio desplegado sin `COCKPIT_API_TOKEN` que hoy purga caché sin cabecera empezará a recibir 503 tras actualizar la app Go. Es intencional: hoy ese endpoint es público.
- Activar la confianza en el proxy cambia la clave del rate limit; los contadores en curso se reinician (sin pérdida de datos).
- Mover los puertos de infra a `127.0.0.1` rompe cualquier herramienta del host que hoy alcance Mongo/Redis por la IP de la LAN.
- `gosite update` dejará de honrar `GOSITE_REPO` desde el entorno.

**Dependencias nuevas**

- `flock` (util-linux) o un fallback basado en `mkdir` para el locking en macOS, donde `flock` no viene de serie.
- `yq` o un comparador YAML propio para el informe de deriva; la decisión se resuelve en `design.md`.

**Fuera de alcance**

- Cifrar en reposo la API key de Replica y el `webhookSecret` de Forms (ambos se guardan hoy en claro en Mongo). Queda documentado como riesgo aceptado, no se aborda aquí.
- Migrar el CLI fuera de Bash.
