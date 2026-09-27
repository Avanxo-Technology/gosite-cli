import test from "node:test"
import assert from "node:assert/strict"

import { deleteAbandonedCarts, type CartStore } from "../src/lib/cleanup.ts"

// A fake cart module holding carts in memory, paginating like Medusa does.
function fakeStore(carts: Array<{ id: string; completed: boolean; updated: Date }>) {
  const calls: number[] = []
  const store: CartStore = {
    async listCarts(filters, config) {
      calls.push(config.take)
      const cutoff = (filters.updated_at as { $lt: Date }).$lt
      return carts
        .filter((c) => !c.completed && c.updated < cutoff)
        .slice(0, config.take)
        .map((c) => ({ id: c.id }))
    },
    async deleteCarts(ids) {
      for (const id of ids) {
        carts.splice(carts.findIndex((c) => c.id === id), 1)
      }
    },
  }
  return { store, carts, calls }
}

const old = new Date("2026-01-01")
const cutoff = new Date("2026-06-01")
const recent = new Date("2026-09-01")

test("deletes every abandoned cart, not only the first page", async () => {
  const carts = Array.from({ length: 40 }, (_, i) => ({ id: `c${i}`, completed: false, updated: old }))
  const { store, carts: left } = fakeStore(carts)
  assert.equal(await deleteAbandonedCarts(store, cutoff, 15), 40)
  assert.equal(left.length, 0)
})

test("keeps completed carts and recent ones", async () => {
  const { store, carts } = fakeStore([
    { id: "abandoned", completed: false, updated: old },
    { id: "ordered", completed: true, updated: old },
    { id: "active", completed: false, updated: recent },
  ])
  assert.equal(await deleteAbandonedCarts(store, cutoff), 1)
  assert.deepEqual(carts.map((c) => c.id), ["ordered", "active"])
})

test("nothing to delete is zero", async () => {
  const { store } = fakeStore([])
  assert.equal(await deleteAbandonedCarts(store, cutoff), 0)
})
