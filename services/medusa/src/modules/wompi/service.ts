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

import { buildCheckoutURL, mapStatus, parseWebhookEvent, toCents, type EventPayload } from "./wompi"

export type WompiOptions = {
  publicKey: string
  privateKey: string
  integritySecret: string
  eventsSecret: string
  baseURL?: string
  checkoutURL?: string
}

const DEFAULT_BASE_URL = "https://production.wompi.co/v1"
const DEFAULT_CHECKOUT_URL = "https://checkout.wompi.co/p"

type SessionData = Record<string, unknown>

// WompiProviderService talks to Wompi's Web Checkout and API. The signature,
// checksum and status logic lives in ./wompi (pure, unit-tested); this class is
// the thin transport Medusa calls.
class WompiProviderService extends AbstractPaymentProvider<WompiOptions> {
  static identifier = "wompi"

  protected logger: Logger
  protected options_: WompiOptions

  constructor(container: Record<string, unknown>, options: WompiOptions) {
    super(container, options)
    this.logger = (container.resolve as (key: string) => Logger)("logger")
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
    const reference = (context?.payment_session?.id as string) ?? randomUUID()
    const redirectURL = String(context?.redirect_url ?? "")

    const checkoutURL = buildCheckoutURL({
      baseURL: this.options_.checkoutURL ?? DEFAULT_CHECKOUT_URL,
      publicKey: this.options_.publicKey,
      reference,
      amount: String(input.amount),
      currency: input.currency_code.toUpperCase(),
      redirectURL,
      integritySecret: this.options_.integritySecret,
    })

    return {
      id: reference,
      status: "pending",
      data: { reference, checkout_url: checkoutURL, status: "PENDING" },
    }
  }

  // authorizePayment checks the transaction with Wompi before authorizing.
  async authorizePayment(input: AuthorizePaymentInput): Promise<AuthorizePaymentOutput> {
    const reference = input.data?.reference
    if (!reference) {
      return { status: "error", data: input.data }
    }
    const tx = await this.fetchTransaction(String(reference))
    // The transaction id is kept on the session: refunds need it.
    return {
      status: tx.status,
      data: { ...input.data, status: tx.status.toUpperCase(), transaction_id: tx.id },
    }
  }

  async getPaymentStatus(input: GetPaymentStatusInput): Promise<GetPaymentStatusOutput> {
    const reference = input.data?.reference
    if (!reference) {
      return { status: "error", data: input.data }
    }
    return { status: (await this.fetchTransaction(String(reference))).status, data: input.data }
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
    return this.options_.baseURL ?? DEFAULT_BASE_URL
  }

  private apiHeaders(): Record<string, string> {
    return {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.options_.privateKey}`,
    }
  }

  // fetchTransaction looks a transaction up by reference. A missing one or an
  // API failure is status "error" with no id.
  private async fetchTransaction(
    reference: string
  ): Promise<{ id?: string; status: "authorized" | "pending" | "error" }> {
    const response = await fetch(
      `${this.baseURL()}/transactions?reference=${encodeURIComponent(reference)}`,
      { headers: this.apiHeaders() }
    )
    if (!response.ok) {
      return { status: "error" }
    }
    const body = (await response.json()) as { data?: Array<{ id?: string; status?: string }> }
    const tx = body.data?.[0]
    return { id: tx?.id, status: mapStatus(String(tx?.status ?? "ERROR")) }
  }
}

export default WompiProviderService
