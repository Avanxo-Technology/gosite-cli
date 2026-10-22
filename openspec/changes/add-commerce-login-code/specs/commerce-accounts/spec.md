## ADDED Requirements

### Requirement: Sign in with a code sent by e-mail
The commerce service SHALL e-mail a six-digit code to an address on the site's request and SHALL answer a right code typed back with a customer token for that address.

#### Scenario: Returning buyer
- **WHEN** an address with an account asks for a code and types it back within 10 minutes
- **THEN** the site gets a token that `/store/customers/me` accepts for that account

#### Scenario: New address
- **WHEN** an address without an account types back its code
- **THEN** an account is created for it and the answer is `created`

#### Scenario: Guest orders
- **WHEN** an address that bought as a guest signs in with a code
- **THEN** its guest orders belong to the account afterwards

#### Scenario: Addresses from orders
- **WHEN** an account with an empty address book signs in, or guest orders move into it
- **THEN** its orders' shipping addresses are among its saved addresses, once each, the newest the default

### Requirement: Codes are limited and never stored in clear
A code SHALL expire after 10 minutes and after five wrong tries, an address SHALL get at most one code a minute and five an hour, and neither the code table nor the Mailer log SHALL hold the code itself.

#### Scenario: Asking again at once
- **WHEN** an address asks for a second code within a minute
- **THEN** the answer is `too_soon` with the seconds to wait and no e-mail is sent

#### Scenario: Guessing
- **WHEN** five wrong codes are typed
- **THEN** the code no longer works, even typed right, and a new one must be asked for

#### Scenario: The log
- **WHEN** a code e-mail is sent
- **THEN** its delivery in Admin › Mailer shows `••••••` in place of the code

### Requirement: The store chooses the code's e-mail
The code SHALL be sent only through an active Mailer rule on `gosite.customer.login_code`, and the site SHALL learn at once whether it left.

#### Scenario: No rule
- **WHEN** no active rule names the event
- **THEN** the request answers `no_rule` and no code is kept

#### Scenario: SMTP down
- **WHEN** the SMTP server cannot be reached
- **THEN** the request answers `send_failed`, the code is spent and the e-mail is not retried later
