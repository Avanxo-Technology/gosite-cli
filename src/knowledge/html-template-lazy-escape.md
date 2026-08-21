# html/template — Lazy escaping and sticky escapeErr

## The problem

`html/template` in Go performs **contextual escaping lazily** — not at
`Parse`/`ParseFS` time, but at the first `Execute` call. If the escaping
analysis finds a problem (e.g. a quote in an attribute name from Alpine.js
syntax conflicts), the error is **cached in `t.escapeErr`** and every
subsequent `Execute` on that template returns the same error until the
process restarts.

Symptoms:
- First request after boot fails with `html/template:layout: "'" in attribute name`
- Every subsequent request fails identically (cached error)
- In dev with `air`, the process restart on file-save "fixes" it
  (new binary → fresh template → escape passes if the file was corrected)
- In prod, the page is **permanently broken** until deploy/restart

Verified in Go source (`html/template/template.go`):

```go
func (t *Template) escape() error {
    ...
    if t.escapeErr == nil {
        if err := escapeTemplate(t, t.text.Root, t.Name()); err != nil {
            return err  // cached internally
        }
    } else if t.escapeErr != escapeOK {
        return t.escapeErr  // sticky: returned on every Execute
    }
    return nil
}
```

## The fix: startup probe

Force the escape pass at boot by executing each page template into
`io.Discard` with minimal probe data:

```go
probeData := map[string]any{
    "Title":   "",
    "Content": map[string]any{},
    "IsDev":   true,
}
for name, t := range pages {
    if err := t.ExecuteTemplate(io.Discard, "layout", probeData); err != nil {
        panic(fmt.Sprintf("views: page %q failed at startup: %v", name, err))
    }
}
```

If probeData is missing a key that the template uses with `index`, the
probe panics with "index of untyped nil". Add the missing key to
`probeData` — this is a one-time fix per project.

## Alpine.js + Go template quoting rules

The escaping error typically comes from HTML attributes containing
conflicting quotes. Safe patterns:

```html
<!-- GOOD: single quotes inside double-quoted attribute -->
<div x-text="'Hello ' + name"></div>

<!-- BAD: single-quoted attribute with embedded single quotes -->
<div x-text='' + name + ''></div>

<!-- GOOD: use toJSON for complex data in x-data -->
<section x-data="{{toJSON .Content.testimonials}}">

<!-- BAD: raw JS concatenation in attribute -->
<section x-data="var t = {{.Content}} + 'foo'">
```

Rule: HTML attributes always use `"double quotes"`. JavaScript strings
inside use `'single quotes'`. Use `toJSON` for marshaling data into
`x-data`.
