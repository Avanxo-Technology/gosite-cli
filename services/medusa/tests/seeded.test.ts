import test from "node:test"
import assert from "node:assert/strict"

import { pickSeeded, usableKeys } from "../src/lib/seeded.ts"

test("a recorded record is reused even when renamed", async () => {
  let fallbackCalled = false
  const found = await pickSeeded("reg_1", [{ id: "reg_1", name: "Colombia (tienda)" }], async () => {
    fallbackCalled = true
    return []
  })
  assert.deepEqual(found, { id: "reg_1", name: "Colombia (tienda)" })
  assert.equal(fallbackCalled, false)
})

test("without a recorded id the default lookup adopts a record", async () => {
  const found = await pickSeeded(undefined, [], async () => [{ id: "reg_legacy" }])
  assert.deepEqual(found, { id: "reg_legacy" })
})

test("a recorded record that was deleted falls back, and nothing means create", async () => {
  assert.equal(await pickSeeded("reg_gone", [], async () => []), undefined)
})

test("revoked keys are never reused", () => {
  const keys = [
    { id: "k1", revoked_at: "2026-09-19T00:00:00Z" },
    { id: "k2", revoked_at: null },
  ]
  assert.deepEqual(usableKeys(keys), [{ id: "k2", revoked_at: null }])
  assert.deepEqual(usableKeys([{ id: "k1", revoked_at: new Date() }]), [])
})
