import { createHmac, randomInt, timingSafeEqual } from "node:crypto"

// Signing in by e-mail code. A buyer types their address on the site, gets a
// six-digit code by e-mail and types it back; the code proves the address is
// theirs, so an address without an account gets one. Pure: the routes in
// api/store/gosite/login-code load and store the codes.

// LOGIN_CODE_EVENT is the mailer event of the code's e-mail. It is never
// emitted on the event bus: the request route renders and sends its rules
// itself, so the site learns at once whether the e-mail left.
export const LOGIN_CODE_EVENT = "gosite.customer.login_code"

export const CODE_TTL_MINUTES = 10
// A new code for the same address waits this long after the last one.
export const RESEND_AFTER_SECONDS = 60
// At most this many codes per address in an hour.
export const MAX_CODES_PER_HOUR = 5
// Wrong codes before a code is spent and a new one must be asked for.
export const MAX_VERIFY_ATTEMPTS = 5

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

// normalizeLoginEmail is the address as codes and accounts store it, or ""
// when it is not one.
export function normalizeLoginEmail(email: unknown): string {
  const value = typeof email === "string" ? email.trim().toLowerCase() : ""
  return value.length <= 254 && EMAIL.test(value) ? value : ""
}

export function generateCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0")
}

// hashCode binds a code to its address, keyed by the server's secret, so the
// table alone does not reveal codes (six digits are quick to brute force from
// an unkeyed hash).
export function hashCode(secret: string, email: string, code: string): string {
  return createHmac("sha256", secret).update(`${email}:${code}`).digest("hex")
}

// cleanCode keeps the digits a buyer typed ("123 456" and "123-456" are
// 123456).
export function cleanCode(code: unknown): string {
  return typeof code === "string" ? code.replace(/[\s-]/g, "") : ""
}

export interface IssuedCode {
  created_at: Date | string
}

export type RequestDecision = { kind: "send" } | { kind: "too_soon"; retryAfterSeconds: number }

// decideRequest says whether a new code may be sent, given the codes the
// address got in the last hour.
export function decideRequest(recent: IssuedCode[], now: Date): RequestDecision {
  const times = recent.map((c) => new Date(c.created_at).getTime()).filter((t) => now.getTime() - t < 3_600_000)
  if (!times.length) {
    return { kind: "send" }
  }
  const last = Math.max(...times)
  const wait = Math.ceil((last + RESEND_AFTER_SECONDS * 1000 - now.getTime()) / 1000)
  if (wait > 0) {
    return { kind: "too_soon", retryAfterSeconds: wait }
  }
  if (times.length >= MAX_CODES_PER_HOUR) {
    const oldest = Math.min(...times)
    return { kind: "too_soon", retryAfterSeconds: Math.ceil((oldest + 3_600_000 - now.getTime()) / 1000) }
  }
  return { kind: "send" }
}

export interface StoredCode {
  code_hash: string
  expires_at: Date | string
  attempts: number
  consumed_at?: Date | string | null
}

export type VerifyDecision =
  | { kind: "ok" }
  // No usable code: none sent, spent, or past its time. A new one is needed.
  | { kind: "expired" }
  | { kind: "too_many_attempts" }
  | { kind: "wrong"; attemptsLeft: number }

// decideVerify checks a typed code against the address's latest one.
export function decideVerify(stored: StoredCode | null, typedHash: string, now: Date): VerifyDecision {
  if (!stored || stored.consumed_at || new Date(stored.expires_at).getTime() <= now.getTime()) {
    return { kind: "expired" }
  }
  if (stored.attempts >= MAX_VERIFY_ATTEMPTS) {
    return { kind: "too_many_attempts" }
  }
  const a = Buffer.from(stored.code_hash)
  const b = Buffer.from(typedHash)
  if (a.length === b.length && timingSafeEqual(a, b)) {
    return { kind: "ok" }
  }
  const left = MAX_VERIFY_ATTEMPTS - stored.attempts - 1
  return left > 0 ? { kind: "wrong", attemptsLeft: left } : { kind: "too_many_attempts" }
}

// redact hides a code in what the mailer keeps of its e-mail: Admin › Mailer
// shows deliveries, and a code there would let anyone with the Admin sign in
// as the buyer.
export function redact(text: string, code: string): string {
  return code ? text.split(code).join("••••••") : text
}
