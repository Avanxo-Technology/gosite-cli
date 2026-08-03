# gremco-test

Go (Echo + htmx + Alpine.js + Templ) + Cockpit CMS monolith, with Redis
cache-aside in front of the CMS.

## Local development

```bash
gosite infra up      # shared Postgres + Redis on gosite-network
gosite start         # app (air hot reload) + Cockpit
```

| Service | URL |
| --- | --- |
| App | http://localhost:8000 |
| Cockpit | http://localhost:8001 |

Editing any `.go` or `.templ` file triggers `templ generate` + rebuild via air.

## Caching

`GET /articulos` reads through Redis (`gremco-test:articles:v1`, TTL 10m).
The `X-Cache` response header reports `HIT` or `MISS`. Point a Cockpit publish
webhook at `POST /cache/purge` (header `X-Api-Key: $COCKPIT_API_TOKEN`) to
invalidate on demand.

## Production (Coolify)

`docker-compose.prod.yml` publishes no host ports and takes every value from
the environment. In Coolify: create a Docker Compose resource from this repo,
select `docker-compose.prod.yml`, then set `SERVICE_FQDN_APP`,
`SERVICE_FQDN_CMS`, `REDIS_URL`, `DATABASE_URL` and `COCKPIT_API_TOKEN`.
