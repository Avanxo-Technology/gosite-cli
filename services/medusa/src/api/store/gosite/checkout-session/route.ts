import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"
import { createCustomerAccountWorkflow } from "@medusajs/medusa/core-flows"
import { generateJwtTokenForAuthIdentity } from "@medusajs/medusa/api/auth/utils/generate-jwt-token"

import {
  ACCOUNT_CREATED,
  decideSession,
  EMAIL_CODE_PROVIDER,
  normalizeEmail,
  sharedTokenMatches,
} from "../../../../lib/checkout-session"

// POST /store/gosite/checkout-session { cart_id }: the session of the buyer
// who just paid (see lib/checkout-session). Only the site calls it: /store is
// not routed publicly, and the request must carry the token the site and
// Medusa share (X-Gosite-Token, GOSITE_PURGE_TOKEN).
//
// Answers { status, email, customer_id?, token? }: "created" or "reissued"
// with a customer token, "existing_account" (the order now belongs to that
// account; no token), "pending", "canceled", "expired" or "not_found".

const PAID = new Set(["authorized", "completed"])

type OrderRow = {
  id: string
  email: string
  created_at: string
  status: string
  metadata?: Record<string, unknown> | null
  shipping_address?: { first_name?: string; last_name?: string; phone?: string } | null
  payment_collections?: Array<{ status?: string } | null> | null
}

export async function POST(req: MedusaRequest<{ cart_id?: string }>, res: MedusaResponse) {
  if (!sharedTokenMatches(req.get("x-gosite-token"), process.env.GOSITE_PURGE_TOKEN)) {
    return res.status(401).json({ status: "unauthorized" })
  }
  const cartID = typeof req.body?.cart_id === "string" ? req.body.cart_id : ""
  if (!cartID) {
    return res.status(400).json({ status: "invalid", message: "cart_id is required" })
  }

  const query = req.scope.resolve(ContainerRegistrationKeys.QUERY)
  const { data: links } = await query.graph({
    entity: "order_cart",
    fields: ["order_id"],
    filters: { cart_id: cartID },
  })
  const orderID = (links[0] as { order_id?: string } | undefined)?.order_id
  if (!orderID) {
    return res.status(404).json({ status: "not_found" })
  }

  // One buyer's page asks repeatedly while it waits: serialize per order so
  // two calls never create two accounts.
  const locking = req.scope.resolve(Modules.LOCKING)
  const answer = await locking.execute(`gosite-checkout-session:${orderID}`, () =>
    openSession(req, orderID)
  )
  return res.status(answer.code).json(answer.body)
}

async function openSession(req: MedusaRequest, orderID: string) {
  const query = req.scope.resolve(ContainerRegistrationKeys.QUERY)
  const customerModule = req.scope.resolve(Modules.CUSTOMER)
  const orderModule = req.scope.resolve(Modules.ORDER)
  const authModule = req.scope.resolve(Modules.AUTH)

  const { data: rows } = await query.graph({
    entity: "order",
    fields: [
      "id",
      "email",
      "created_at",
      "status",
      "metadata",
      "shipping_address.first_name",
      "shipping_address.last_name",
      "shipping_address.phone",
      "payment_collections.status",
    ],
    filters: { id: orderID },
  })
  const order = rows[0] as unknown as OrderRow
  const email = normalizeEmail(order.email ?? "")

  const accounts = await customerModule.listCustomers(
    { email: [...new Set([order.email, email])], has_account: true },
    { select: ["id"], take: 1 }
  )
  const decision = decideSession(
    {
      id: order.id,
      email,
      createdAt: new Date(order.created_at),
      canceled: order.status === "canceled",
      paid: (order.payment_collections ?? []).some((c) => PAID.has(String(c?.status))),
      accountCreatedFor: order.metadata?.[ACCOUNT_CREATED] as string | undefined,
    },
    accounts[0] ? { customerID: accounts[0].id } : null,
    new Date()
  )

  switch (decision.kind) {
    case "pending":
    case "canceled":
    case "expired":
      return { code: 409, body: { status: decision.kind, email } }

    case "existing_account":
      await orderModule.updateOrders(order.id, { customer_id: decision.customerID })
      return {
        code: 200,
        body: { status: "existing_account", email, customer_id: decision.customerID },
      }

    case "reissue": {
      const identity = await emailCodeIdentity(authModule, email)
      if (!identity) {
        return { code: 409, body: { status: "existing_account", email, customer_id: decision.customerID } }
      }
      return {
        code: 200,
        body: {
          status: "reissued",
          email,
          customer_id: decision.customerID,
          token: await customerToken(req, identity),
        },
      }
    }

    case "create": {
      // An identity left by an attempt that failed before its customer was
      // created is reused rather than duplicated.
      let identity = await emailCodeIdentity(authModule, email)
      if (!identity) {
        identity = await authModule.createAuthIdentities({
          provider_identities: [{ provider: EMAIL_CODE_PROVIDER, entity_id: email }],
        })
      }
      const { result: customer } = await createCustomerAccountWorkflow(req.scope).run({
        input: {
          authIdentityId: identity.id,
          customerData: {
            email,
            first_name: order.shipping_address?.first_name || undefined,
            last_name: order.shipping_address?.last_name || undefined,
            phone: order.shipping_address?.phone || undefined,
          },
        },
      })
      await orderModule.updateOrders(order.id, {
        customer_id: customer.id,
        metadata: { ...(order.metadata ?? {}), [ACCOUNT_CREATED]: customer.id },
      })
      // The account workflow wrote customer_id into the identity's app_metadata;
      // the token is built from the stored identity.
      const stored = await authModule.retrieveAuthIdentity(identity.id, {
        relations: ["provider_identities"],
      })
      return {
        code: 200,
        body: { status: "created", email, customer_id: customer.id, token: await customerToken(req, stored) },
      }
    }
  }
}

// emailCodeIdentity is the auth identity of the address's e-mail code login,
// if it exists.
async function emailCodeIdentity(authModule: any, email: string) {
  const providers = await authModule.listProviderIdentities(
    { provider: EMAIL_CODE_PROVIDER, entity_id: email },
    { select: ["auth_identity_id"], take: 1 }
  )
  const id = providers[0]?.auth_identity_id
  return id ? authModule.retrieveAuthIdentity(id, { relations: ["provider_identities"] }) : null
}

// customerToken is the token Medusa's own login would give this identity: the
// same signing secret, lifetime and claims, so /store/customers/me accepts it
// and /auth/token/refresh renews it.
async function customerToken(req: MedusaRequest, authIdentity: any): Promise<string> {
  const { http } = req.scope.resolve(ContainerRegistrationKeys.CONFIG_MODULE).projectConfig
  if (!http.jwtSecret) {
    throw new Error("checkout-session: JWT_SECRET is not set")
  }
  return generateJwtTokenForAuthIdentity(
    { authIdentity, actorType: "customer", authProvider: EMAIL_CODE_PROVIDER, container: req.scope },
    { secret: http.jwtSecret, expiresIn: http.jwtExpiresIn, options: http.jwtOptions }
  )
}
