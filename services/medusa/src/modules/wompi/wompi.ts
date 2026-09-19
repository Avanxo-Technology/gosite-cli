import { createHash, timingSafeEqual as cryptoEqual } from "node:crypto"

// Wompi amounts are "cents": the amount in the currency's major unit times 100,
// COP included (design D5: a 59.900 COP cart is 5990000 to Wompi). Medusa
// stores amounts as decimals in the major unit, so the conversion is exact
// multiplication by 100. Strings and BigInt avoid 19.99 * 100 = 1998.9999...

const FACTOR = 100

// toCents("19.99") -> 1999 ; toCents("59900") -> 5990000
export function toCents(amount: string | number): number {
  const text = normalize(String(amount).trim())
  const negative = text.startsWith("-")
  const absolute = negative ? text.slice(1) : text
  const [intPart, fracPart = ""] = absolute.split(".")

  if (fracPart.length > 2) {
    throw new Error(`amount ${amount} has more precision than the currency allows (2 decimals)`)
  }

  const frac = fracPart.padEnd(2, "0")
  const digits = `${intPart}${frac}`.replace(/^0+(?=\d)/, "") || "0"
  const value = BigInt(digits)
  return Number(negative ? -value : value)
}

// fromCents(1999) -> "19.99" ; fromCents(5990000) -> "59900"
export function fromCents(cents: number): string {
  if (!Number.isInteger(cents)) {
    throw new Error(`cents must be an integer, got ${cents}`)
  }
  const negative = cents < 0
  const digits = BigInt(Math.abs(cents)).toString().padStart(3, "0")
  const intPart = digits.slice(0, digits.length - 2)
  const fracPart = digits.slice(digits.length - 2)
  // Wompi's cents for a zero-decimal currency come back as a whole amount.
  const suffix = fracPart === "00" ? "" : `.${fracPart}`
  return `${negative ? "-" : ""}${intPart}${suffix}`
}

function normalize(text: string): string {
  if (!/^-?\d+(\.\d+)?$/.test(text) || text === "-") {
    throw new Error(`invalid amount: ${text}`)
  }
  return text
}

// The Wompi statuses we care about, mapped to Medusa's payment states.
export type WompiStatus = "APPROVED" | "PENDING" | "DECLINED" | "VOIDED" | "ERROR"

export function mapStatus(status: string): "authorized" | "pending" | "error" {
  switch (status?.toUpperCase()) {
    case "APPROVED":
      return "authorized"
    case "PENDING":
      return "pending"
    default:
      return "error"
  }
}

// integritySignature is the SHA-256 Wompi requires on a Web Checkout URL:
// reference + amount-in-cents + currency + integrity secret.
export function integritySignature(
  reference: string,
  amountInCents: number,
  currency: string,
  integritySecret: string
): string {
  return sha256(`${reference}${amountInCents}${currency}${integritySecret}`)
}

export interface CheckoutOptions {
  baseURL: string
  publicKey: string
  reference: string
  amount: string | number
  currency: string
  redirectURL: string
  integritySecret: string
}

// buildCheckoutURL builds the Web Checkout URL, with the integrity signature
// Wompi validates before showing the payment methods.
export function buildCheckoutURL(options: CheckoutOptions): string {
  const amountInCents = toCents(options.amount)
  const signature = integritySignature(
    options.reference,
    amountInCents,
    options.currency,
    options.integritySecret
  )
  const query = new URLSearchParams({
    "public-key": options.publicKey,
    currency: options.currency,
    "amount-in-cents": String(amountInCents),
    reference: options.reference,
    "signature:integrity": signature,
    "redirect-url": options.redirectURL,
  })
  return `${options.baseURL.replace(/\/$/, "")}/?${query.toString()}`
}

// EventPayload is the shape of a Wompi event: data plus the signature block
// Wompi signs.
export interface EventPayload {
  event?: string
  data?: Record<string, unknown>
  sent_at?: string
  timestamp?: number
  signature?: {
    properties?: string[]
    checksum?: string
  }
}

// verifyEventChecksum checks the event's checksum: the concatenated values of
// the signed properties, then the timestamp, then the events secret.
export function verifyEventChecksum(event: EventPayload, eventsSecret: string): boolean {
  const properties = event.signature?.properties
  const checksum = event.signature?.checksum
  if (!properties?.length || !checksum) {
    return false
  }
  const timestamp = event.timestamp ?? event.sent_at
  if (timestamp === undefined) {
    return false
  }
  // Wompi's properties are paths inside the event's data object.
  const base: unknown = event.data ?? event
  const values = properties.map((path) => String(readPath(base, path) ?? ""))
  const expected = sha256(`${values.join("")}${timestamp}${eventsSecret}`)
  return timingSafeEqual(expected, checksum)
}

// WebhookResult is what a verified Wompi event means for Medusa. amount is in
// the currency's major unit, as Medusa stores it: Wompi reports cents, and
// passing those through would record a payment 100 times the cart total.
export type WebhookResult =
  | { valid: false }
  | {
      valid: true
      status: "authorized" | "pending" | "error"
      sessionID: string
      amount: string
    }

export function parseWebhookEvent(event: EventPayload, eventsSecret: string): WebhookResult {
  if (!verifyEventChecksum(event, eventsSecret)) {
    return { valid: false }
  }
  const transaction = (event.data?.transaction ?? {}) as Record<string, unknown>
  const cents = Number(transaction.amount_in_cents ?? 0)
  return {
    valid: true,
    status: mapStatus(String(transaction.status ?? "")),
    sessionID: String(transaction.reference ?? ""),
    amount: Number.isInteger(cents) ? fromCents(cents) : "0",
  }
}

// readPath reads a dotted path ("transaction.status") out of a value.
function readPath(base: unknown, path: string): unknown {
  const parts = path.split(".")
  let current: unknown = base
  for (const part of parts) {
    if (current && typeof current === "object" && part in (current as Record<string, unknown>)) {
      current = (current as Record<string, unknown>)[part]
    } else {
      return undefined
    }
  }
  return current
}

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex")
}

// timingSafeEqual compares two hex digests without leaking where they differ.
function timingSafeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8")
  const right = Buffer.from(b, "utf8")
  if (left.length !== right.length) {
    return false
  }
  return cryptoEqual(left, right)
}
