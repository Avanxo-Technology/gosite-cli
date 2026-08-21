# Cockpit cold-render 502 after cache TTL

## Symptom

After the cache TTL (10 min), the first visitor gets a `502 {"message":"could not load the page"}`. A reload immediately works.

## Root cause

The cache-aside pattern: TTL expires → cold render → Cockpit call.

`CMS.Singleton()` retries once (5s timeout + 1s sleep + 5s timeout). If
Cockpit is cold (PHP-FPM opcache, Mongo reconnect, DNS) and both attempts
fail, `Singleton` returns an empty `Content{}`.

The guard in `renderHome` catches this:

```go
if len(content) == 0 {
    return nil, fmt.Errorf("cockpit returned empty content for home singleton")
}
```

The cache layer discards the error (nothing cached). The next request
retries, Cockpit is now warm → render succeeds → cached for 10 min.

## Fixes

### stale-if-error (`cache.go`)

On render failure, serve the last good copy from a long-lived stale key
instead of returning 502:

```go
const staleTTL = 24 * time.Hour

// On render error:
stale, staleErr := c.rdb.Get(bg, staleKey(key)).Bytes()
if staleErr == nil {
    c.log.Warn("render failed, serving stale", "key", key, "err", err)
    return stale, nil  // visitor sees slightly outdated content
}
return nil, err  // only 502 if no stale copy exists
```

Fresh key TTL: 10 min. Stale key TTL: 24h. Both written on success.
`Purge()` deletes both.

### Parallel CMS fetches (`home.go`)

When `renderHome` makes multiple sequential CMS calls within one context
deadline, they can blow the budget on cold Cockpit. Parallelize with
errgroup:

```go
var (
    content  cms.Content
    featured []cms.Content
)
g, ctx := errgroup.WithContext(ctx)
g.Go(func() error { content = h.CMS.Singleton(ctx, "home"); return nil })
g.Go(func() error { featured = h.CMS.Collection(ctx, "featured"); return nil })
_ = g.Wait()
```

## Diagnosis

Check app logs for:

```
level=WARN msg="cockpit fetch failed, retrying" ...
level=WARN msg="cockpit unavailable after retry, using template fallbacks" ...
```

These appear when Cockpit is unreachable. With stale-if-error, you'll
also see:

```
level=WARN msg="render failed, serving stale" ...
```
