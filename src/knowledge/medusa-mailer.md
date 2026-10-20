# The store's e-mails (gosite-medusa mailer)

Checked on `gosite-medusa:0.59.0` (Medusa 2.21.2) with Mailpit as the SMTP
server.

## Turning it on

- Set the CMS's SMTP variables for the environment: `SMTP_HOST`, `SMTP_PORT`
  (587), `SMTP_ENCRYPTION` (tls, ssl or none), `SMTP_USER`, `SMTP_PASSWORD`,
  `SMTP_FROM` (a sender the provider verified), `SMTP_FROM_NAME`. Medusa reads
  the same ones. Optional: `MAILER_STORE_NAME`, `MAILER_STORE_URL`,
  `MAILER_LOGO_URL` (shown by the templates), `MAILER_LOCALE` (es-CO).
- In Medusa Admin › Mailer, create a rule from a starting template, edit it
  and switch it on. Without an active rule nothing is sent; without SMTP the
  e-mail is logged as skipped.

## Which event

- A site that places the order before payment (Wompi, 0.58.0): e-mail on
  `gosite.order.paid` (payment confirmed, about a minute after it) and
  `gosite.order.expired` (cancelled because nobody paid). Leave
  `order.placed` off: it fires when the buyer presses "Pagar".
- A site that completes the cart after payment: `order.placed` works.
- `order.canceled` from the expire job carries `no_notification`, so the
  mailer skips it; a cancellation by staff in the Admin does send.
- Custom events from a site's own code: list them in `MAILER_EXTRA_EVENTS`
  (restart Medusa), emit them with an `email` field and choose "The event's
  email field".

## Templates

Go template syntax, values escaped: `{{ $.order.display_id }}`,
`{{ range $.order.items }}{{ .product_title }}{{ end }}`,
`{{ if .x }}…{{ else }}…{{ end }}`, `{{ raw .x }}` for HTML. Amounts come
formatted as `*_display` (`$.order.total_display`). The editor lists the
variables. A starting template is copied into the rule: later releases never
change it.

## Testing locally

Run Mailpit on the commerce network (`axllent/mailpit`, SMTP on 1025, web on
8025) and point Medusa at it: `SMTP_HOST=<container>`, `SMTP_PORT=1025`,
`SMTP_ENCRYPTION=none`, `SMTP_FROM=tienda@example.test`. The Admin's session
cookie needs HTTPS, so open the Admin through Traefik, not `localhost:9000`.
