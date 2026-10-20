import { randomUUID } from "node:crypto"

import { AbstractPaymentProvider, MedusaError, PaymentActions } from "@medusajs/framework/utils"
import type {
  AuthorizePaymentInput,
  AuthorizePaymentOutput,
  CancelPaymentInput,
  CancelPaymentOutput,
  CapturePaymentInput,
  CapturePaymentOutput,
  DeletePaymentInput,
  DeletePaymentOutput,
  GetPaymentStatusInput,
  GetPaymentStatusOutput,
  InitiatePaymentInput,
  InitiatePaymentOutput,
  Logger,
  ProviderWebhookPayload,
  RefundPaymentInput,
  RefundPaymentOutput,
  RetrievePaymentInput,
  RetrievePaymentOutput,
  UpdatePaymentInput,
  UpdatePaymentOutput,
  WebhookActionResult,
} from "@medusajs/framework/types"

import {
  authorizationStatus,
  buildCheckoutURL,
  parseWebhookEvent,
  sessionReference,
  toCents,
  type EventPayload,
} from "./wompi"

export type WompiOptions = {
  publicKey: string
  privateKey: string
  integritySecret: string
  eventsSecret: string
  baseURL?: string
  checkoutURL?: string
  // How long a buyer has to start paying, in minutes: the checkout URL expires
  // then. Unset or 0: the URL does not expire.
  expirationMinutes?: number
}

const DEFAULT_BASE_URL = "https://production.wompi.co/v1"
const DEFAULT_CHECKOUT_URL = "https://checkout.wompi.co/p"

// A transaction Wompi holds for a reference; undefined status when there is
// none yet.
type Transaction = { id?: string; status?: string }

type SessionData = Record<string, unknown>

// WompiProviderService talks to Wompi's Web Checkout and API. The signature,
// checksum and status logic lives in ./wompi (pure, unit-tested); this class is
// the thin transport Medusa calls.
class WompiProviderService extends AbstractPaymentProvider<WompiOptions> {
  static identifier = "wompi"

  protected logger: Logger
  protected options_: WompiOptions

  // Medusa hands a provider the container's cradle, not the container: a
  // dependency is a property, and the cradle has no resolve().
  constructor(container: { logger: Logger }, options: WompiOptions) {
    super(container, options)
    this.logger = container.logger
    this.options_ = options
  }

  static validateOptions(options: Record<string, unknown>): void {
    for (const key of ["publicKey", "privateKey", "integritySecret", "eventsSecret"]) {
      if (!options[key]) {
        throw new MedusaError(
          MedusaError.Types.INVALID_DATA,
          `Wompi is registered but ${key} is missing`
        )
      }
    }
  }

  // initiatePayment returns the Web Checkout URL and the reference Wompi will
  // report back. The reference is the payment session id, so a webhook maps to
  // exactly one session.
  async initiatePayment(input: InitiatePaymentInput): Promise<InitiatePaymentOutput> {
    const context = input.context as unknown as Record<string, any>
    const reference = sessionReference(input.data, context) ?? randomUUID()
    const redirectURL = String(context?.redirect_url ?? "")

    const minutes = Number(this.options_.expirationMinutes ?? 0)

    const checkoutURL = buildCheckoutURL({
      // Compose passes an unset variable as "": that is no URL either.
      baseURL: this.options_.checkoutURL || DEFAULT_CHECKOUT_URL,
      publicKey: this.options_.publicKey,
      reference,
      amount: String(input.amount),
      currency: input.currency_code.toUpperCase(),
      redirectURL,
      integritySecret: this.options_.integritySecret,
      expirationTime:
        minutes > 0 ? new Date(Date.now() + minutes * 60_000).toISOString() : undefined,
    })

    return {
      id: reference,
      status: "pending",
      data: { reference, checkout_url: checkoutURL, status: "PENDING" },
    }
  }

  // authorizePayment checks the transaction with Wompi. Completing the cart
  // calls it before the buyer has paid: no transaction yet is
  // pending_authorization, so the order is created and its stock reserved
  // while the payment is awaited (see authorizationStatus). The webhook and the
  // expire-pending-payments job call it again once Wompi has an answer.
  async authorizePayment(input: AuthorizePaymentInput): Promise<AuthorizePaymentOutput> {
    const reference = input.data?.reference
    if (!reference) {
      return { status: "error", data: input.data }
    }
    const tx = await this.fetchTransaction(String(reference))
    // The transaction id is kept on the session: refunds need it.
    // transaction_status tells the job whether the buyer has started paying.
    return {
      status: authorizationStatus(tx.status),
      data: {
        ...input.data,
        status: tx.status ?? "NONE",
        transaction_status: tx.status ? tx.status.toLowerCase() : "none",
        transaction_id: tx.id,
      },
    }
  }

  async getPaymentStatus(input: GetPaymentStatusInput): Promise<GetPaymentStatusOutput> {
    const reference = input.data?.reference
    if (!reference) {
      return { status: "error", data: input.data }
    }
    const tx = await this.fetchTransaction(String(reference))
    return { status: authorizationStatus(tx.status), data: input.data }
  }

  async capturePayment(input: CapturePaymentInput): Promise<CapturePaymentOutput> {
    // Web Checkout captures on approval; nothing to do.
    return { data: input.data }
  }

  // refundPayment calls Wompi's refund API for the amount Medusa asks to refund
  // (a partial refund refunds only that part). A refund that cannot reach Wompi
  // throws: returning quietly would show the order as refunded in Medusa Admin
  // while the buyer's money stays charged.
  async refundPayment(input: RefundPaymentInput): Promise<RefundPaymentOutput> {
    let transactionID = input.data?.transaction_id as string | undefined
    if (!transactionID && input.data?.reference) {
      transactionID = (await this.fetchTransaction(String(input.data.reference))).id
    }
    if (!transactionID) {
      throw new MedusaError(
        MedusaError.Types.NOT_ALLOWED,
        "Wompi refund: the payment has no Wompi transaction to refund"
      )
    }
    const amount = toCents(String(input.amount))
    const response = await fetch(`${this.baseURL()}/transactions/${encodeURIComponent(transactionID)}/refunds`, {
      method: "POST",
      headers: this.apiHeaders(),
      body: JSON.stringify({ amount_in_cents: amount }),
    })
    if (!response.ok) {
      throw new MedusaError(
        MedusaError.Types.UNEXPECTED_STATE,
        `Wompi refund failed: ${response.status}`
      )
    }
    return { data: input.data }
  }

  async cancelPayment(input: CancelPaymentInput): Promise<CancelPaymentOutput> {
    const transactionID = input.data?.transaction_id
    if (transactionID) {
      await fetch(`${this.baseURL()}/transactions/${transactionID}/void`, {
        method: "POST",
        headers: this.apiHeaders(),
      })
    }
    return { data: input.data }
  }

  async deletePayment(input: DeletePaymentInput): Promise<DeletePaymentOutput> {
    return { data: input.data }
  }

  async retrievePayment(input: RetrievePaymentInput): Promise<RetrievePaymentOutput> {
    return { data: input.data }
  }

  async updatePayment(input: UpdatePaymentInput): Promise<UpdatePaymentOutput> {
    return { data: input.data }
  }

  // getWebhookActionAndData verifies the event checksum and maps the status. A
  // forged event is not_supported and changes nothing.
  async getWebhookActionAndData(
    payload: ProviderWebhookPayload["payload"]
  ): Promise<WebhookActionResult> {
    const result = parseWebhookEvent(
      payload.data as unknown as EventPayload,
      this.options_.eventsSecret
    )
    if (!result.valid) {
      this.logger.warn("wompi: rejected a webhook with an invalid checksum")
      return { action: PaymentActions.NOT_SUPPORTED, data: { session_id: "", amount: 0 } }
    }
    const { sessionID, amount, status } = result

    const action =
      status === "authorized"
        ? PaymentActions.AUTHORIZED
        : status === "pending"
          ? PaymentActions.PENDING
          : PaymentActions.FAILED

    return { action, data: { session_id: sessionID, amount } }
  }

  private baseURL(): string {
    return this.options_.baseURL || DEFAULT_BASE_URL
  }

  private apiHeaders(): Record<string, string> {
    return {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.options_.privateKey}`,
    }
  }

  // fetchTransaction looks a transaction up by reference: no status when Wompi
  // has none yet. An API failure throws, so it is never mistaken for "the
  // buyer has not paid": Medusa then retries instead of acting on it.
  private async fetchTransaction(reference: string): Promise<Transaction> {
    const response = await fetch(
      `${this.baseURL()}/transactions?reference=${encodeURIComponent(reference)}`,
      { headers: this.apiHeaders() }
    )
    if (!response.ok) {
      throw new MedusaError(
        MedusaError.Types.UNEXPECTED_STATE,
        `Wompi transaction lookup failed: ${response.status}`
      )
    }
    const body = (await response.json()) as { data?: Transaction[] }
    const tx = body.data?.[0]
    return { id: tx?.id, status: tx?.status ? String(tx.status).toUpperCase() : undefined }
  }
}

export default WompiProviderService
