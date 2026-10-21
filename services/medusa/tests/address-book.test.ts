import test from "node:test"
import assert from "node:assert/strict"

import { addressesToSave, addressKey, MAX_SEEDED_ADDRESSES } from "../src/lib/address-book.ts"

const home = { first_name: "Ana", last_name: "Ruiz", address_1: "Calle 1 # 2-3", city: "Cali", province: "Valle del Cauca", country_code: "co", phone: "300" }

test("the same place for the same person is one address, whatever the case, spaces or phone", () => {
  assert.equal(addressKey(home), addressKey({ ...home, address_1: "  calle 1  #  2-3 ", city: "CALI", phone: "311" }))
  assert.notEqual(addressKey(home), addressKey({ ...home, address_2: "Apto 2" }))
  assert.notEqual(addressKey(home), addressKey({ ...home, first_name: "Luis" }))
})

test("order addresses the book lacks are saved once, newest first, with their fields only", () => {
  const office = { ...home, address_1: "Carrera 9 # 10-11", city: "Bogotá", province: "Bogotá D.C.", id: "caaddr_x", metadata: null }
  const out = addressesToSave([office, home, { ...home, city: "cali" }, null], [])
  assert.equal(out.length, 2)
  assert.equal(out[0].address_1, "Carrera 9 # 10-11")
  assert.equal((out[0] as Record<string, unknown>).id, undefined)
  assert.equal(out[1].address_1, "Calle 1 # 2-3")
})

test("addresses already saved, and ones without a street or city, are skipped", () => {
  assert.deepEqual(addressesToSave([home], [{ ...home, phone: "999" }]), [])
  assert.deepEqual(addressesToSave([{ ...home, address_1: " " }, { ...home, city: null }], []), [])
})

test("at most a handful come from orders at once", () => {
  const many = Array.from({ length: 9 }, (_, i) => ({ ...home, address_1: `Calle ${i}` }))
  assert.equal(addressesToSave(many, []).length, MAX_SEEDED_ADDRESSES)
})
