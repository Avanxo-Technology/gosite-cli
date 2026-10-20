import { timingSafeEqual } from "node:crypto"

// The session a buyer gets right after paying, on the browser that placed the
// order. The site asks for it with the order's cart id, which only that
// browser holds; nobody else can name the cart.
//
// The checkout's e-mail address is not verified, so a session is only handed
// out for an account this very order created. When the address already has an
// account, the order is attached to it and no session is given: the buyer
// signs in to it (by e-mail code) like anyone else.

// EMAIL_CODE_PROVIDER is the auth provider of accounts created at checkout.
// They have no password: signing in later is by a code sent to the address.
export const EMAIL_CODE_PROVIDER = "email-code"

// ACCOUNT_CREATED is the order metadata key naming the customer this order
// created an account for.
export const ACCOUNT_CREATED = "gosite_account_customer_id"

// SESSION_WINDOW_HOURS is how long after the order its cart id still opens a
// session. Later the buyer signs in instead.
export const SESSION_WINDOW_HOURS = 24

export interface SessionOrder {
  id: string
  email: string
  createdAt: Date
  canceled: boolean
  // An authorized or captured payment covers the order.
  paid: boolean
  // The customer this order already created an account for, if any.
  accountCreatedFor?: string
}

// An existing account with the order's address, if any.
export interface Account {
  customerID: string
}

export type SessionDecision =
  | { kind: "pending" }
  | { kind: "canceled" }
  | { kind: "expired" }
  // The address has an account this order did not create: attach the order.
  | { kind: "existing_account"; customerID: string }
  // No account yet: create one and open its session.
  | { kind: "create" }
  // This order created the account (an earlier call): open its session again.
  | { kind: "reissue"; customerID: string }

export function decideSession(order: SessionOrder, account: Account | null, now: Date): SessionDecision {
  if (order.canceled) {
    return { kind: "canceled" }
  }
  if (!order.paid) {
    return { kind: "pending" }
  }
  if (now.getTime() - order.createdAt.getTime() > SESSION_WINDOW_HOURS * 3_600_000) {
    return { kind: "expired" }
  }
  if (account) {
    return order.accountCreatedFor === account.customerID
      ? { kind: "reissue", customerID: account.customerID }
      : { kind: "existing_account", customerID: account.customerID }
  }
  return { kind: "create" }
}

// normalizeEmail is the form an address is stored and looked up in.
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase()
}

// sharedTokenMatches checks the token the site sends against the one it
// shares with Medusa (GOSITE_PURGE_TOKEN). No configured token disables the
// route: it never answers to an empty secret.
export function sharedTokenMatches(sent: string | undefined, expected: string | undefined): boolean {
  if (!expected || !sent) {
    return false
  }
  const a = Buffer.from(sent)
  const b = Buffer.from(expected)
  return a.length === b.length && timingSafeEqual(a, b)
}
