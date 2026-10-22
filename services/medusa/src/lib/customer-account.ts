import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"
import { createCustomerAccountWorkflow } from "@medusajs/medusa/core-flows"
import { generateJwtTokenForAuthIdentity } from "@medusajs/medusa/api/auth/utils/generate-jwt-token"

import { addressesToSave, type Address } from "./address-book"
import { EMAIL_CODE_PROVIDER } from "./checkout-session"

// Buyer accounts without a password: the "email-code" auth identity of an
// address, and the customer token Medusa's own login would give it. Used by
// the checkout session (an account made by a paid order) and by signing in
// with an e-mail code.

// emailCodeIdentity is the auth identity of the address's e-mail code login,
// if it exists.
export async function emailCodeIdentity(container: MedusaContainer, email: string) {
  const authModule = container.resolve(Modules.AUTH)
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
export async function customerToken(container: MedusaContainer, authIdentity: any): Promise<string> {
  const { http } = container.resolve(ContainerRegistrationKeys.CONFIG_MODULE).projectConfig
  if (!http.jwtSecret) {
    throw new Error("customer account: JWT_SECRET is not set")
  }
  return generateJwtTokenForAuthIdentity(
    { authIdentity, actorType: "customer", authProvider: EMAIL_CODE_PROVIDER, container },
    { secret: http.jwtSecret as string, expiresIn: http.jwtExpiresIn, options: http.jwtOptions }
  )
}

// registeredCustomer is the address's account, if it has one.
export async function registeredCustomer(container: MedusaContainer, email: string): Promise<{ id: string } | null> {
  const customerModule = container.resolve(Modules.CUSTOMER)
  const accounts = await customerModule.listCustomers({ email, has_account: true }, { select: ["id"], take: 1 })
  return accounts[0] ? { id: accounts[0].id } : null
}

// createEmailCodeAccount registers the address: its e-mail code identity
// (reused when an earlier attempt left one) and a customer.
export async function createEmailCodeAccount(
  container: MedusaContainer,
  email: string,
  data: { first_name?: string; last_name?: string; phone?: string } = {}
) {
  const authModule = container.resolve(Modules.AUTH)
  let identity = await emailCodeIdentity(container, email)
  if (!identity) {
    identity = await authModule.createAuthIdentities({
      provider_identities: [{ provider: EMAIL_CODE_PROVIDER, entity_id: email }],
    })
  }
  const { result: customer } = await createCustomerAccountWorkflow(container).run({
    input: {
      authIdentityId: identity.id,
      customerData: {
        email,
        first_name: data.first_name || undefined,
        last_name: data.last_name || undefined,
        phone: data.phone || undefined,
      },
    },
  })
  // The account workflow wrote customer_id into the identity's app_metadata;
  // a token is built from the stored identity.
  const stored = await authModule.retrieveAuthIdentity(identity.id, { relations: ["provider_identities"] })
  return { customer, identity: stored }
}

// signInIdentity is the e-mail code identity that signs in to an existing
// account. An account made another way (a password, the Admin) gets one, so
// its owner can sign in with a code too.
export async function signInIdentity(container: MedusaContainer, email: string, customerID: string) {
  const authModule = container.resolve(Modules.AUTH)
  const identity = await emailCodeIdentity(container, email)
  if (!identity) {
    return authModule.createAuthIdentities({
      provider_identities: [{ provider: EMAIL_CODE_PROVIDER, entity_id: email }],
      app_metadata: { customer_id: customerID },
    })
  }
  if ((identity.app_metadata as Record<string, unknown> | null)?.customer_id !== customerID) {
    await authModule.updateAuthIdentities({
      id: identity.id,
      app_metadata: { ...(identity.app_metadata ?? {}), customer_id: customerID },
    })
    return authModule.retrieveAuthIdentity(identity.id, { relations: ["provider_identities"] })
  }
  return identity
}

// claimGuestOrders moves the address's guest orders into its account and
// returns their ids. Only once the address is proven (a code typed back): the
// checkout's address alone proves nothing.
export async function claimGuestOrders(container: MedusaContainer, email: string, customerID: string): Promise<string[]> {
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const orderModule = container.resolve(Modules.ORDER)
  const { data } = await query.graph({
    entity: "order",
    fields: ["id", "customer_id", "customer.has_account"],
    filters: { email },
  })
  const guest = (data as Array<{ id: string; customer_id?: string | null; customer?: { has_account?: boolean } | null }>).filter(
    (o) => o.customer_id !== customerID && !o.customer?.has_account
  )
  for (const order of guest) {
    await orderModule.updateOrders(order.id, { customer_id: customerID })
  }
  return guest.map((o) => o.id)
}

// fillAddressBook saves the shipping addresses of orders that just came into
// the account (orderIDs) among its addresses, skipping ones it holds. An
// empty book is filled from all the account's orders instead, so accounts
// made before this existed get theirs on their next sign-in. The newest
// address becomes the default when the book has none. Best effort: a failure
// is logged and never stops a sign-in or a checkout.
export async function fillAddressBook(container: MedusaContainer, customerID: string, orderIDs: string[]): Promise<number> {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  try {
    const customerModule = container.resolve(Modules.CUSTOMER)
    const query = container.resolve(ContainerRegistrationKeys.QUERY)
    const saved = (await customerModule.listCustomerAddresses({ customer_id: customerID }, { take: 100 })) as unknown as Array<
      Address & { is_default_shipping?: boolean }
    >
    const filters = saved.length ? { id: orderIDs } : { customer_id: customerID }
    if (saved.length && !orderIDs.length) {
      return 0
    }
    const { data } = await query.graph({ entity: "order", fields: ["id", "created_at", "shipping_address.*"], filters })
    const orders = (data as Array<{ created_at: string; shipping_address?: Address | null }>).sort(
      (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
    )
    const add = addressesToSave(
      orders.map((o) => o.shipping_address),
      saved
    )
    if (!add.length) {
      return 0
    }
    const hasDefault = saved.some((a) => a.is_default_shipping)
    await customerModule.createCustomerAddresses(
      add.map((a, i) => ({ ...a, customer_id: customerID, is_default_shipping: !hasDefault && i === 0 })) as never
    )
    return add.length
  } catch (error) {
    logger.warn(`customer account: addresses of ${customerID} not saved: ${(error as Error).message}`)
    return 0
  }
}
