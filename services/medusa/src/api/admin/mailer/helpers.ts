import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

import { loadContext, type MailContext } from "../../../lib/mailer/send"
import { CODE_TTL_MINUTES, LOGIN_CODE_EVENT } from "../../../lib/login-code"
import { resourceOf } from "../../../lib/mailer/rules"

// sampleContext is what a preview or a test e-mail renders with: the order
// (or customer) the Admin picked, else the most recent one, as if the event
// had just fired for it.
export async function sampleContext(
  container: MedusaContainer,
  event: string,
  orderID?: string
): Promise<{ context: MailContext; sample: string }> {
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  if (event === LOGIN_CODE_EVENT) {
    // A made-up code: a real one is only ever in the buyer's e-mail.
    const context = await loadContext(container, event, {
      email: "comprador@ejemplo.com",
      code: "123456",
      expires_in_minutes: CODE_TTL_MINUTES,
      new_account: false,
    })
    return { context, sample: "sample code 123456" }
  }
  const type = resourceOf(event, { id: "x" }).type
  if (type === "customer") {
    const { data } = await query.graph({
      entity: "customer",
      fields: ["id", "email"],
      pagination: { take: 1, order: { created_at: "DESC" } },
    })
    const customer = (data as Array<{ id: string; email?: string }>)[0]
    const context = await loadContext(container, event, customer ? { id: customer.id } : {})
    return { context, sample: customer ? `customer ${customer.email ?? customer.id}` : "no customer yet" }
  }
  let id = orderID
  if (!id) {
    const { data } = await query.graph({
      entity: "order",
      fields: ["id"],
      pagination: { take: 1, order: { created_at: "DESC" } },
    })
    id = (data as Array<{ id: string }>)[0]?.id
  }
  if (!id) {
    return { context: await loadContext(container, event, {}), sample: "no order yet" }
  }
  // Shipment and delivery events carry a fulfillment; a sample renders the
  // order alone.
  const context = await loadContext(container, type === "fulfillment" ? "order.placed" : event, { id })
  context.event = event
  const displayID = (context.order as { display_id?: unknown } | null)?.display_id
  return { context, sample: displayID ? `order #${displayID}` : `order ${id}` }
}
