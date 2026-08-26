# Cockpit core — the model registry is cached, and debug hides it

Writing a content model through `$app->module('content')->createModel()` /
`updateModel()` stores the definition correctly in the database, but the model
is **not visible to the running application** until the model registry is
rebuilt.

## Why

`Content\Helper\Model` keeps every model definition under the `content.models`
memory key, and only bypasses that cache when debug is on:

```php
$this->models = $this->app['debug']
    ? $this->cache(false)
    : $this->app->memory->get('content.models', ...);
```

So on any **non-debug** environment the write lands in the database while the
in-memory registry still describes the world as it was.

## How it presents

The symptoms do not look like a caching problem, which is what makes this
expensive to diagnose:

- the REST API answers `Model <name> not found`
- a consuming app reads the singleton as empty and renders its fallbacks
- inspecting the database shows the definition present and correct

## Why it stays hidden

Development runs with debug on, where the registry is rebuilt on every request.
The bug is invisible locally and only appears on staging or production —
exactly where it is hardest to look.

## The fix

After writing model definitions programmatically, rebuild the registry:

```php
$this->app->helper('content.model')->cache(true);
```

Treat the rebuild as best-effort: the data is already written, and the next
request rebuilds the registry anyway, so a failure here should be reported
rather than allowed to fail the whole operation.

## Where this bit us

`Replica`'s `applyModels()` replicated models to a non-debug destination and
they stayed invisible there (fixed in gosite 0.44.0). Any code path that writes
model definitions outside the admin UI has the same exposure — including
`Forms`' and any future addon's `ensureModels()`, whenever it creates a model
on an environment running with debug off.
