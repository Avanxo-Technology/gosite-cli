import test from "node:test"
import assert from "node:assert/strict"

import { createDebouncer } from "../src/lib/debounce.ts"

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

test("a burst of calls runs the action once", async () => {
  let calls = 0
  const schedule = createDebouncer(20, () => {
    calls++
  })
  for (let i = 0; i < 10; i++) {
    schedule()
  }
  assert.equal(calls, 0, "the action must not run before the window closes")
  await sleep(60)
  assert.equal(calls, 1)
})

test("a later burst runs the action again", async () => {
  let calls = 0
  const schedule = createDebouncer(20, () => {
    calls++
  })
  schedule()
  await sleep(60)
  schedule()
  await sleep(60)
  assert.equal(calls, 2)
})
