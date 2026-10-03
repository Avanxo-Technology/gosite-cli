import test from "node:test"
import assert from "node:assert/strict"

import { s3FileModule, s3Prefix } from "../src/lib/file-storage.ts"

const s3Env = {
  STORAGE_ADAPTER: "s3",
  S3_URL: "https://gosite-minio:9000",
  S3_BUCKET: "assets",
  S3_REGION: "us-east-1",
  S3_KEY: "key",
  S3_SECRET: "secret",
  S3_PREFIX: "",
  S3_PUBLIC_URL: "https://minio.test/assets/",
}

function providerOptions(mod: Record<string, unknown> | null) {
  assert.ok(mod)
  const providers = (mod.options as { providers: Array<{ options: Record<string, unknown> }> }).providers
  return providers[0].options
}

test("no S3 storage keeps Medusa's default provider", () => {
  assert.equal(s3FileModule({}), null)
  assert.equal(s3FileModule({ ...s3Env, STORAGE_ADAPTER: "local" }), null)
  assert.equal(s3FileModule({ ...s3Env, S3_SECRET: "" }), null)
})

test("S3 storage uploads to the site's bucket under medusa/", () => {
  const mod = s3FileModule(s3Env)
  assert.equal(mod?.resolve, "@medusajs/medusa/file")
  const o = providerOptions(mod)
  assert.equal(o.bucket, "assets")
  assert.equal(o.endpoint, "https://gosite-minio:9000")
  assert.equal(o.file_url, "https://minio.test/assets")
  assert.equal(o.prefix, "medusa/")
  assert.equal(o.acl, undefined)
  const client = o.additional_client_config as Record<string, unknown>
  assert.equal(client.forcePathStyle, true)
  assert.equal(client.requestHandler, undefined)
})

test("S3_VERIFY=false skips TLS verification, and only then", () => {
  const client = providerOptions(s3FileModule({ ...s3Env, S3_VERIFY: "false" }))
    .additional_client_config as Record<string, { httpsAgent: { options: { rejectUnauthorized: boolean } } }>
  assert.equal(client.requestHandler.httpsAgent.options.rejectUnauthorized, false)
})

test("S3_ACL is passed through when set", () => {
  assert.equal(providerOptions(s3FileModule({ ...s3Env, S3_ACL: "private" })).acl, "private")
})

test("S3 without a public URL is a configuration error", () => {
  assert.throws(() => s3FileModule({ ...s3Env, S3_PUBLIC_URL: "" }), /S3_PUBLIC_URL is required/)
})

test("the site's prefix is kept in front of medusa/", () => {
  assert.equal(s3Prefix(undefined), "medusa/")
  assert.equal(s3Prefix("aldu"), "aldu/medusa/")
  assert.equal(s3Prefix("/aldu/"), "aldu/medusa/")
})
