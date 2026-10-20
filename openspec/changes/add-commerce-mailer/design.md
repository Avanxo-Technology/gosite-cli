## Context

Medusa 2.21 emits events on its Redis event bus (`order.placed`, `order.canceled`, `shipment.created`, ...); subscribers run inside Medusa. It has no outgoing webhooks and no SMTP. `payment.captured` is emitted only by `capturePaymentWorkflow`; when a provider reports a payment captured while authorizing it (Wompi), no payment event fires, which a probe on a webhook-paid order confirmed (only `order.placed` and `customer.created`).

## Decisions

**D1. A module in the image, not a separate plugin package.** The mailer lives in `services/medusa` like the Wompi module: one image serves every store, a release ships it, and no store installs anything. Alternative: `@sam-ael/medusa-plugin-mailer`. Rejected: fixed event list without gosite's events, peer-pinned to Medusa 2.12.4, `order.placed` as the confirmation.

**D2. Rules in the database, HTML edited in the Admin.** A rule holds its own subject and HTML. Starting templates are copied when a rule is created, so a release never changes an e-mail a store already sends.

**D3. Explicit event list.** The subscriber listens to the store events (orders, order edits, fulfilment, payments, customers, auth, invites), gosite's and `MAILER_EXTRA_EVENTS`. A wildcard (`*`) would make every internal event go through the queue. Adding an extra event needs a restart (Medusa reads subscriber config at start).

**D4. gosite.order.paid from a sweep.** Medusa's webhook path gives no hook after authorization, so `notify-paid-orders` runs every minute: orders created within the pending window whose collection is paid with a payment created in the last 2 hours and no `gosite_paid_announced_at` metadata get the event, then the flag. Emitted before flagging (at least once); the mailer's per-record dedupe keeps it to one e-mail. The 2-hour window means enabling the job never announces old orders.

**D5. Once per record by a unique key.** A delivery row is inserted before sending with `dedupe_key = rule:event:record` (unique). A repeated event fails the insert and sends nothing. Rules with `once` off (e.g. `order.updated`) get no key.

**D6. SMTP like the CMS.** `SMTP_HOST`, `SMTP_PORT` (587), `SMTP_ENCRYPTION` (tls/ssl/none), `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM` (or SMTP_USER when it is an address), `SMTP_FROM_NAME`. Short timeouts (10 s connect) so a dead server fails fast; `mailer-retry` resends failed rows.

**D7. Go template syntax.** Values are HTML-escaped; `raw` writes HTML. A missing value renders empty (Go's missingkey=zero). Syntax errors are rejected on save and shown in the preview.

## Risks / Trade-offs

- Payment e-mails follow the payment by up to a minute (D4).
- The HTML is trusted: whoever has Admin access writes it. Previews render in a sandboxed iframe (no scripts).
- A rule on `order.placed` in a store that places orders before payment would e-mail unpaid orders; the starter is named "Pedido recibido" and the docs point to `gosite.order.paid`.
