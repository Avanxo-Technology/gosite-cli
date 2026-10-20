## ADDED Requirements

### Requirement: Rules decide which events e-mail
The commerce service SHALL send an e-mail for an event only through an active rule for that event, and each store SHALL manage its rules in the Admin.

#### Scenario: Store that places orders before payment
- **WHEN** a rule on `gosite.order.paid` is active and the rule on `order.placed` is not
- **THEN** the buyer gets one e-mail when the payment is confirmed and none when the order is placed

#### Scenario: No active rule
- **WHEN** an event fires and no active rule names it
- **THEN** nothing is sent or recorded

### Requirement: Templates edited in the Admin
A rule SHALL hold its own subject and HTML, edited in a textarea in the Admin, rendered with the event's record, with a preview from a real order and a test send to a given address.

#### Scenario: Syntax error
- **WHEN** a rule is saved with `{{ if .x }}` and no `{{ end }}`
- **THEN** it is rejected with the error on the HTML field

#### Scenario: Values are escaped
- **WHEN** a value contains `<b>`
- **THEN** it is written as `&lt;b&gt;` unless the template uses `raw`

### Requirement: Payment confirmed and order expired events
The commerce service SHALL emit `gosite.order.paid` once per order whose payment is confirmed and `gosite.order.expired` when it cancels an order nobody paid.

#### Scenario: Webhook-paid order
- **WHEN** Wompi's webhook confirms a payment
- **THEN** `gosite.order.paid` is emitted for the order within about a minute, once

#### Scenario: Unpaid order cancelled by the job
- **WHEN** `expire-pending-payments` cancels an order
- **THEN** `gosite.order.expired` is emitted for it and Medusa's `order.canceled` carries `no_notification`

### Requirement: Each e-mail once, failures retried
A rule that sends once per record SHALL never send twice for the same record, and an e-mail the SMTP server did not accept SHALL be retried.

#### Scenario: Repeated event
- **WHEN** the same event fires twice for one order
- **THEN** one e-mail is sent

#### Scenario: SMTP down
- **WHEN** sending fails
- **THEN** the e-mail is recorded as failed and resent by `mailer-retry`, up to 5 attempts within a day
