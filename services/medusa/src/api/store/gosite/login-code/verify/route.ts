import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"

import { sharedTokenMatches } from "../../../../../lib/checkout-session"
import {
  claimGuestOrders,
  createEmailCodeAccount,
  customerToken,
  fillAddressBook,
  registeredCustomer,
  signInIdentity,
} from "../../../../../lib/customer-account"
import { cleanCode, decideVerify, hashCode, normalizeLoginEmail } from "../../../../../lib/login-code"
import { LOGIN_CODE_MODULE } from "../../../../../modules/login-code"
import type LoginCodeModuleService from "../../../../../modules/login-code/service"
import { secret } from "../route"

// POST /store/gosite/login-code/verify { email, code }: the code typed back.
// Right, it signs the address in, creating its account when it has none, and
// moves the address's guest orders into the account, their addresses into
// its saved ones (lib/customer-account fillAddressBook). Same token as the
// request route.
//   200 { status: "signed_in" | "created", customer_id, token, claimed_orders, saved_addresses }
//   400 { status: "wrong", attempts_left } | { status: "expired" } | { status: "invalid" }
//   429 { status: "too_many_attempts" }          ask for a new code
export async function POST(req: MedusaRequest<{ email?: string; code?: string }>, res: MedusaResponse) {
  if (!sharedTokenMatches(req.get("x-gosite-token"), process.env.GOSITE_PURGE_TOKEN)) {
    return res.status(401).json({ status: "unauthorized" })
  }
  const email = normalizeLoginEmail(req.body?.email)
  const code = cleanCode(req.body?.code)
  if (!email || !/^\d{6}$/.test(code)) {
    return res.status(400).json({ status: "invalid" })
  }
  const locking = req.scope.resolve(Modules.LOCKING)
  const answer = await locking.execute(`gosite-login-code:${email}`, () => verify(req, email, code))
  return res.status(answer.code).json(answer.body)
}

async function verify(req: MedusaRequest, email: string, code: string) {
  const codes: LoginCodeModuleService = req.scope.resolve(LOGIN_CODE_MODULE)
  const now = new Date()
  const [latest] = await codes.listLoginCodes({ email }, { order: { created_at: "DESC" }, take: 1 })
  const decision = decideVerify(latest ?? null, hashCode(secret(req), email, code), now)
  switch (decision.kind) {
    case "expired":
      return { code: 400, body: { status: "expired" } }
    case "too_many_attempts":
      if (latest && !latest.consumed_at) {
        await codes.updateLoginCodes({ id: latest.id, attempts: latest.attempts + 1, consumed_at: now })
      }
      return { code: 429, body: { status: "too_many_attempts" } }
    case "wrong":
      await codes.updateLoginCodes({ id: latest.id, attempts: latest.attempts + 1 })
      return { code: 400, body: { status: "wrong", attempts_left: decision.attemptsLeft } }
  }

  await codes.updateLoginCodes({ id: latest.id, consumed_at: now })
  const account = await registeredCustomer(req.scope, email)
  let customerID: string
  let identity: any
  let status: "signed_in" | "created"
  if (account) {
    customerID = account.id
    identity = await signInIdentity(req.scope, email, account.id)
    status = "signed_in"
  } else {
    const created = await createEmailCodeAccount(req.scope, email)
    customerID = created.customer.id
    identity = created.identity
    status = "created"
  }
  const claimed = await claimGuestOrders(req.scope, email, customerID)
  if (claimed.length) {
    req.scope.resolve(ContainerRegistrationKeys.LOGGER).info(`login code: ${claimed.length} guest order(s) moved into ${customerID}`)
  }
  const addresses = await fillAddressBook(req.scope, customerID, claimed)
  return {
    code: 200,
    body: {
      status,
      customer_id: customerID,
      token: await customerToken(req.scope, identity),
      claimed_orders: claimed.length,
      saved_addresses: addresses,
    },
  }
}
