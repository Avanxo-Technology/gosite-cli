## Why

Stores need transactional e-mail (payment received, order cancelled, order shipped), and Medusa sends none by default: its notification module has no SMTP provider and no templates, and the plugins that add them listen to a fixed event list. With orders placed before payment (0.58.0) the usual confirmation event, `order.placed`, fires when the buyer presses "Pagar", and Medusa emits no event at all when a deferred payment is confirmed. Each store must decide which events e-mail, and edit its own HTML, without a gosite release.

## What Changes

- New module `mailer` built into `gosite-medusa`: rules (event → recipient → subject and HTML template, active flag, once per record) and a log of every e-mail (`mailer_delivery`), with a migration.
- Admin › Mailer (an Admin route): list, create from a starting template, edit the HTML in a textarea with a live preview rendered with a real order, toggle, delete, send a test, and the log of sent e-mails.
- Templates use a subset of Go's html/template (`{{ .x }}`, `{{ if }}`, `{{ range }}`, `{{ else }}`, `{{ raw }}`, `$`), the syntax of gosite's site templates; values are escaped.
- Subscriber `gosite-mailer` listens to Medusa's store events, gosite's events and `MAILER_EXTRA_EVENTS`; only active rules send. Medusa's `no_notification` is honoured.
- New gosite events: `gosite.order.paid` (job `notify-paid-orders`, every minute, once per order whose payment was confirmed in the last 2 hours) and `gosite.order.expired` (emitted by `expire-pending-payments` when it cancels an unpaid order).
- Sending through SMTP (nodemailer) with the CMS's `SMTP_*` variables; failures retried by job `mailer-retry` (every 5 minutes, 5 attempts, for a day). Compose templates pass `SMTP_*` and `MAILER_*` to Medusa.

## Capabilities

### New Capabilities
- `commerce-mailer`: store e-mails on chosen events, edited per store in the Admin.

### Modified Capabilities
- `commerce-pending-orders`: cancelling an unpaid order also emits `gosite.order.expired`.

## Impact

- `services/medusa/`: `src/modules/mailer/`, `src/lib/mailer/`, `src/lib/paid-orders.ts`, `src/subscribers/mailer.ts`, `src/jobs/{notify-paid-orders,mailer-retry}.ts`, `src/api/admin/mailer/`, `src/admin/routes/mailer/`, `medusa-config.ts`, `src/jobs/expire-pending-payments.ts`. New dependency `nodemailer`. New optional env: `MAILER_STORE_NAME`, `MAILER_STORE_URL`, `MAILER_LOGO_URL`, `MAILER_LOCALE`, `MAILER_EXTRA_EVENTS`.
- Sites: regenerate (`gosite generate`) to pass the variables to Medusa; nothing is sent until SMTP is set and a rule is active.
- Not in this change: the sign-in code e-mail (it will be a rule on the event the `email-code` provider emits).
