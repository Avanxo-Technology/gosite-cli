# MinIO S3 SSL + env propagation — Known fixes

## 1. GuzzleHttp `verify` option — must be nested under `http`

The consolidated Webapp addon builds the S3 client constructor options in
`cockpit/addons/Webapp/bootstrap.php` (section "CloudStorage"). AWS SDK v3 uses GuzzleHttp
internally, and the TLS verification flag must go inside the `http` key —
**not** at the root of `$s3Opts`:

```php
// BROKEN — verify at root level, Guzzle ignores it:
$s3Opts['verify'] = false;

// WORKING — verify nested under http:
$s3Opts['http'] = ['verify' => false];
```

Root-level `verify` is silently ignored; the SDK still performs TLS
verification, causing self-signed cert errors against MinIO.

## 2. Environment variable must be declared in `docker-compose.yml`

Adding a variable to `.env` is not enough — it must also appear in the
CMS service's `environment:` block so Docker passes it into the container:

```yaml
environment:
  S3_ACL: "${S3_ACL:-}"
  S3_VERIFY: "${S3_VERIFY:-}"   # ← add this
```

Without this, `S3_VERIFY=false` in `.env` never reaches the PHP process.

## 3. Asset path mismatch in MongoDB

After replication or manual DB edits, the `path` stored in the assets
collection can diverge from the actual object key in MinIO. Symptoms:
images return 404 from S3 while Cockpit admin still shows them.

Diagnosis: compare the `path` field in MongoDB against the object key
in the MinIO bucket.

Fix: update the MongoDB document directly to match the real S3 key:

```js
db.getCollection('assets').updateOne(
  { _id: ObjectId("...") },
  { $set: { path: "/2026/08/11/correct-filename.webp" } }
)
```

Common cause: re-uploading or replicating an asset with a different
timestamp in the path (e.g. `08/17` vs original `08/11`).
