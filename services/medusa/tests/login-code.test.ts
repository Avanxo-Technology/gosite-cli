import test from "node:test"
import assert from "node:assert/strict"

import {
  cleanCode,
  CODE_TTL_MINUTES,
  decideRequest,
  decideVerify,
  generateCode,
  hashCode,
  MAX_CODES_PER_HOUR,
  MAX_VERIFY_ATTEMPTS,
  normalizeLoginEmail,
  redact,
} from "../src/lib/login-code.ts"
import { renderHTML, renderText } from "../src/lib/mailer/template.ts"
import { STARTERS } from "../src/lib/mailer/starters.ts"
import { mailerEvents, resolveRecipients } from "../src/lib/mailer/rules.ts"

const now = new Date("2026-10-21T15:00:00Z")
const ago = (seconds: number) => new Date(now.getTime() - seconds * 1000)

test("addresses are lower-cased and anything else is refused", () => {
  assert.equal(normalizeLoginEmail("  Ana@Empresa.COM "), "ana@empresa.com")
  assert.equal(normalizeLoginEmail("ana@empresa"), "")
  assert.equal(normalizeLoginEmail("ana empresa.com"), "")
  assert.equal(normalizeLoginEmail(undefined), "")
  assert.equal(normalizeLoginEmail("a".repeat(250) + "@x.co"), "")
})

test("codes are six digits and a typed one keeps only its digits", () => {
  for (let i = 0; i < 200; i++) {
    assert.match(generateCode(), /^\d{6}$/)
  }
  assert.equal(cleanCode(" 123 456 "), "123456")
  assert.equal(cleanCode("123-456"), "123456")
  assert.equal(cleanCode(42), "")
})

test("a code's hash depends on the secret, the address and the code", () => {
  const h = hashCode("s", "ana@x.co", "123456")
  assert.equal(h, hashCode("s", "ana@x.co", "123456"))
  assert.notEqual(h, hashCode("t", "ana@x.co", "123456"))
  assert.notEqual(h, hashCode("s", "luis@x.co", "123456"))
  assert.notEqual(h, hashCode("s", "ana@x.co", "123457"))
})

test("a new code waits a minute after the last and five per hour", () => {
  assert.deepEqual(decideRequest([], now), { kind: "send" })
  assert.deepEqual(decideRequest([{ created_at: ago(20) }], now), { kind: "too_soon", retryAfterSeconds: 40 })
  assert.deepEqual(decideRequest([{ created_at: ago(61) }], now), { kind: "send" })
  const five = [3000, 2400, 1800, 1200, 600].map((s) => ({ created_at: ago(s) }))
  assert.equal(five.length, MAX_CODES_PER_HOUR)
  assert.deepEqual(decideRequest(five, now), { kind: "too_soon", retryAfterSeconds: 600 })
  // Codes older than an hour do not count.
  assert.deepEqual(decideRequest([{ created_at: ago(4000) }, { created_at: ago(3700) }], now), { kind: "send" })
})

test("a typed code is checked against the latest one, its time and its attempts", () => {
  const hash = hashCode("s", "ana@x.co", "123456")
  const wrong = hashCode("s", "ana@x.co", "000000")
  const fresh = { code_hash: hash, expires_at: new Date(now.getTime() + 60_000), attempts: 0, consumed_at: null }
  assert.deepEqual(decideVerify(fresh, hash, now), { kind: "ok" })
  assert.deepEqual(decideVerify(fresh, wrong, now), { kind: "wrong", attemptsLeft: MAX_VERIFY_ATTEMPTS - 1 })
  assert.deepEqual(decideVerify({ ...fresh, attempts: MAX_VERIFY_ATTEMPTS - 1 }, wrong, now), { kind: "too_many_attempts" })
  // Spent: even the right code no longer works.
  assert.deepEqual(decideVerify({ ...fresh, attempts: MAX_VERIFY_ATTEMPTS }, hash, now), { kind: "too_many_attempts" })
  assert.deepEqual(decideVerify({ ...fresh, expires_at: now }, hash, now), { kind: "expired" })
  assert.deepEqual(decideVerify({ ...fresh, consumed_at: ago(5) }, hash, now), { kind: "expired" })
  assert.deepEqual(decideVerify(null, hash, now), { kind: "expired" })
})

test("the code never stays in what the mailer keeps", () => {
  assert.equal(redact("Tu código: 123456 (123456)", "123456"), "Tu código: •••••• (••••••)")
  assert.equal(redact("nada", ""), "nada")
})

test("the code's starter renders the code and goes to the event's address", () => {
  assert.ok(mailerEvents({}).includes("gosite.customer.login_code"))
  const starter = STARTERS.find((s) => s.key === "login_code")!
  assert.equal(starter.event, "gosite.customer.login_code")
  const context = {
    event: starter.event,
    data: { email: "ana@x.co", code: "042917", expires_in_minutes: CODE_TTL_MINUTES, new_account: true },
    store: { name: "Tienda", url: "", logo_url: "" },
  }
  assert.equal(renderText(starter.subject, context), "Tu código de acceso: 042917")
  const html = renderHTML(starter.html, context)
  assert.ok(html.includes("042917"))
  assert.ok(html.includes("Crea tu cuenta"))
  assert.ok(renderHTML(starter.html, { ...context, data: { ...context.data, new_account: false } }).includes("Ingresa a tu cuenta"))
  assert.deepEqual(resolveRecipients({ recipient: starter.recipient, recipient_address: null }, context), ["ana@x.co"])
})
