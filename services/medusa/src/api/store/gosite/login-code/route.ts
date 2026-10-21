import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"

import { sharedTokenMatches } from "../../../../lib/checkout-session"
import { registeredCustomer } from "../../../../lib/customer-account"
import {
  CODE_TTL_MINUTES,
  decideRequest,
  generateCode,
  hashCode,
  LOGIN_CODE_EVENT,
  normalizeLoginEmail,
} from "../../../../lib/login-code"
import { storeInfo } from "../../../../lib/mailer/context"
import { deliver, type MailContext } from "../../../../lib/mailer/send"
import type { RuleInput } from "../../../../lib/mailer/rules"
import { LOGIN_CODE_MODULE } from "../../../../modules/login-code"
import type LoginCodeModuleService from "../../../../modules/login-code/service"
import { MAILER_MODULE } from "../../../../modules/mailer"
import type MailerModuleService from "../../../../modules/mailer/service"

// POST /store/gosite/login-code { email }: e-mails a sign-in code to the
// address (lib/login-code). An address without an account gets one when the
// code comes back (./verify). Only the site calls it, with the token it shares
// with Medusa (X-Gosite-Token, GOSITE_PURGE_TOKEN), like checkout-session.
//
// The e-mail is the active Mailer rules of gosite.customer.login_code, sent
// here and now, so the answer says whether it left:
//   200 { status: "sent", new_account, expires_in_minutes }
//   429 { status: "too_soon", retry_after }      a code was sent moments ago
//   503 { status: "no_rule" }                     no active rule for the event
//   502 { status: "send_failed" }                 SMTP refused or is not set
//   400 { status: "invalid_email" }
export async function POST(req: MedusaRequest<{ email?: string }>, res: MedusaResponse) {
  if (!sharedTokenMatches(req.get("x-gosite-token"), process.env.GOSITE_PURGE_TOKEN)) {
    return res.status(401).json({ status: "unauthorized" })
  }
  const email = normalizeLoginEmail(req.body?.email)
  if (!email) {
    return res.status(400).json({ status: "invalid_email" })
  }
  const locking = req.scope.resolve(Modules.LOCKING)
  const answer = await locking.execute(`gosite-login-code:${email}`, () => sendCode(req, email))
  return res.status(answer.code).json(answer.body)
}

async function sendCode(req: MedusaRequest, email: string) {
  const codes: LoginCodeModuleService = req.scope.resolve(LOGIN_CODE_MODULE)
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  const logger = req.scope.resolve(ContainerRegistrationKeys.LOGGER)
  const now = new Date()

  const recent = await codes.listLoginCodes({ email, created_at: { $gte: new Date(now.getTime() - 3_600_000) } })
  const decision = decideRequest(recent, now)
  if (decision.kind === "too_soon") {
    return { code: 429, body: { status: "too_soon", retry_after: decision.retryAfterSeconds } }
  }
  const rules = (await mailer.listMailerRules({ event: LOGIN_CODE_EVENT, active: true })) as unknown as Array<
    RuleInput & { id: string }
  >
  if (!rules.length) {
    logger.warn(`login code: no active Mailer rule for ${LOGIN_CODE_EVENT}; no code sent`)
    return { code: 503, body: { status: "no_rule" } }
  }

  // Only the newest code counts: the ones before it stop working.
  const open = recent.filter((c) => !c.consumed_at)
  if (open.length) {
    await codes.updateLoginCodes(open.map((c) => ({ id: c.id, consumed_at: now })))
  }
  const code = generateCode()
  const stored = await codes.createLoginCodes({
    email,
    code_hash: hashCode(secret(req), email, code),
    expires_at: new Date(now.getTime() + CODE_TTL_MINUTES * 60_000),
  })

  const account = await registeredCustomer(req.scope, email)
  const context: MailContext = {
    event: LOGIN_CODE_EVENT,
    data: { email, code, expires_in_minutes: CODE_TTL_MINUTES, new_account: !account },
    store: storeInfo(process.env),
    customer: account
      ? ((await req.scope.resolve(Modules.CUSTOMER).retrieveCustomer(account.id, {
          select: ["id", "email", "first_name", "last_name"],
        })) as unknown as Record<string, unknown>)
      : null,
  }
  let sent = false
  for (const rule of rules) {
    try {
      sent = (await deliver(req.scope, rule, context, { secret: code, retry: false })) === "sent" || sent
    } catch (error) {
      logger.error(`login code: ${rule.name}: ${(error as Error).message}`)
    }
  }
  if (!sent) {
    // A code nobody received must not linger as the address's latest.
    await codes.updateLoginCodes({ id: stored.id, consumed_at: new Date() })
    return { code: 502, body: { status: "send_failed" } }
  }
  return { code: 200, body: { status: "sent", new_account: !account, expires_in_minutes: CODE_TTL_MINUTES } }
}

// secret keys the codes' hashes: the server's JWT secret, which never leaves
// Medusa.
export function secret(req: MedusaRequest): string {
  const { http } = req.scope.resolve(ContainerRegistrationKeys.CONFIG_MODULE).projectConfig
  if (!http.jwtSecret) {
    throw new Error("login code: JWT_SECRET is not set")
  }
  return String(http.jwtSecret)
}
