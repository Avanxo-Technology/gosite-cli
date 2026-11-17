# Redis memory: the page cache on a shared Redis

Production and QA use the shared Redis of the host through `REDIS_URL`.
gosite does not configure that Redis; `gosite infra` configures only the local
one. This note is what the host's Redis needs, and how to see what fills it.

## What core writes

| Key | TTL | When |
| --- | --- | --- |
| `<project>:<env>:cache:page:<path>` | 10 min | every page served with `CachedRender` |
| `<project>:<env>:cache:page:<path>:stale` | 24 h | only for a URL with **no query left** after tracking parameters are dropped (since 0.71.0) |
| `<project>:<env>:cache:page:<path>?<query>` | 10 min | a URL with a query, normalized |
| `<project>:app:...` | none | app state (`State()`); never purged |

Since 0.71.0 the query in the key is normalized: parameters sorted, values in
one encoding, and tracking parameters (`utm_*`, `gclid`, `fbclid`, `msclkid`,
...) dropped. `?b=2&a=1&utm_source=x` and `?a=1&b=2` are one key.

Before 0.71.0 every query variant had its own key and its own 24-hour stale
copy. On 2026-11-16 crawlers walking the filters of one listing left 47,680
keys (5.27 GB, 99% stale copies) on a Redis with no memory limit.

## The host's Redis

- **Set `maxmemory`.** Without it `maxmemory-policy` never applies and Redis
  grows until the host runs out of memory.
- **Use `volatile-lru`, not `allkeys-lru`.** Cache keys have a TTL and state
  keys do not, so only cache is evicted. `allkeys-lru` can evict API keys and
  other state.
- **Trap:** with `volatile-lru`, when the keys without a TTL alone reach the
  limit, Redis rejects writes (`OOM command not allowed when used memory >
  'maxmemory'`). Leave room above the state's size.
- **Persistence:** every RDB snapshot forks the process. With a large keyspace
  that doubles memory for the fork. For a Redis that is mostly cache, use one
  mode (AOF or RDB), not both.

At runtime, without a restart:

```bash
redis-cli CONFIG SET maxmemory 2gb
redis-cli CONFIG SET maxmemory-policy volatile-lru
```

Put the same values in the Redis service's configuration too, or a restart
loses them.

## See what fills it

```bash
redis-cli INFO memory | grep used_memory_human
redis-cli --scan --pattern '<project>:*:cache:page:*' | wc -l
redis-cli --scan --pattern '<project>:*:cache:page:*?*:stale' | wc -l   # pre-0.71.0 query stale copies
redis-cli MEMORY USAGE '<one key>'
```

Use `--scan` (SCAN), never `KEYS`: on a shared Redis `KEYS` blocks every site.
The pre-0.71.0 query stale copies expire on their own within 24 hours of the
upgrade. To free the memory sooner, delete them with `--scan --pattern ... |
xargs redis-cli UNLINK`. Never delete by `<project>:*`: that also deletes
`<project>:app:` state.

## Local Redis (`gosite infra`)

`--maxmemory ${GOSITE_REDIS_MAXMEMORY}` (default `1gb`) with `volatile-lru`.
Override it in the environment before `gosite infra up`, for example
`GOSITE_REDIS_MAXMEMORY=2gb gosite infra up`.
