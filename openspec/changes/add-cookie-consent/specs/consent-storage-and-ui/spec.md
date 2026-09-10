## ADDED Requirements

### Requirement: A visitor's decision is stored where the visitor can see it and the server cannot

The decision SHALL be stored in a first-party cookie readable by the browser.
It SHALL NOT be stored in a way that makes it visible to server-side rendering,
and no rendered page SHALL vary by it.

#### Scenario: A returning visitor

- **WHEN** a visitor who has already decided loads any page
- **THEN** the stored decision is applied before the banner would paint, and
  the banner does not appear

#### Scenario: A cached page and two visitors

- **WHEN** one visitor accepts, and a second visitor with no cookie loads the
  same cached page
- **THEN** the second visitor is asked, and sees no trace of the first
  visitor's choice

#### Scenario: Storage unavailable

- **WHEN** cookies cannot be written
- **THEN** nothing is tracked, the page renders normally, and no error reaches
  the visitor

### Requirement: Three categories, and a provider belongs to exactly one

Consent SHALL be expressed over exactly three categories: necessary, analytics
and marketing. Necessary SHALL always be granted and SHALL NOT be presented as
refusable. Every provider the site can render SHALL resolve to exactly one
category.

#### Scenario: A provider with no explicit category

- **WHEN** an integration is saved without a category
- **THEN** the provider's own default applies

#### Scenario: An ambiguous provider

- **WHEN** a tag manager's container holds only analytics tags
- **THEN** the site owner can record it as analytics, overriding the safer
  default

#### Scenario: Refusing everything

- **WHEN** a visitor refuses every optional category
- **THEN** the site works, and no provider in a refused category runs

### Requirement: The stored decision records what was agreed to

The cookie SHALL record the granted categories, the time of the decision, the
schema version of the category set, and the version of the copy the visitor was
shown.

#### Scenario: The category set changes

- **WHEN** a release changes which categories exist
- **THEN** an existing decision is treated as absent and the visitor is asked
  again

#### Scenario: The copy changes

- **WHEN** an editor corrects the banner text in the CMS
- **THEN** existing decisions stand, and the new version is recorded on
  decisions made from then on

#### Scenario: An unreadable cookie

- **WHEN** the stored value is malformed or hand-edited
- **THEN** it is treated as no decision at all, not as a partial one

### Requirement: The banner and its copy are content

The banner's copy SHALL come from the CMS: whether consent is asked for at
all, the text, and the link to the privacy policy. Changing any of them SHALL
NOT require a release.

#### Scenario: Editing the copy

- **WHEN** the banner text is changed in the CMS and saved
- **THEN** every cached page of that project is purged and the new text is
  served

#### Scenario: Consent not configured

- **WHEN** the consent singleton has never been filled in
- **THEN** the site renders with no banner and, per the analytics capability,
  loads no gated provider

### Requirement: Granular choice, and withdrawal is as easy as consent

The visitor SHALL be able to accept all, refuse all, or choose per category
from the first interaction. A visitor who has decided SHALL be able to reopen
the choice and change it from any page.

#### Scenario: Choosing per category

- **WHEN** a visitor opens the preferences and grants analytics but not
  marketing
- **THEN** the decision is stored as exactly that

#### Scenario: Reopening from a footer link

- **WHEN** a visitor activates the documented reopen control
- **THEN** the preferences appear with their current choices shown

#### Scenario: Refusing after having accepted

- **WHEN** a visitor withdraws a category they previously granted
- **THEN** the stored decision is updated and the providers in that category
  stop running, without the visitor having to clear anything by hand

### Requirement: The banner is operable without a mouse

The banner and the preferences dialog SHALL be usable by keyboard and
announceable by a screen reader. The dialog SHALL trap focus while open and
close on escape.

#### Scenario: Keyboard only

- **WHEN** a visitor navigates the banner with the keyboard alone
- **THEN** every control is reachable, focus is visible, and the choice can be
  submitted

#### Scenario: The dialog is open

- **WHEN** the preferences dialog has focus
- **THEN** focus stays inside it until it closes, and escape closes it without
  storing a decision

### Requirement: The mechanism is available to the page as a stable API

The browser SHALL expose the current decision, a subscription to changes, a way
to open the preferences, and a way to clear the decision. The API SHALL NOT be
specific to analytics.

#### Scenario: Another consumer

- **WHEN** page code wants to gate an embedded third-party player
- **THEN** it can read the decision and be notified when it changes, without
  referencing analytics

#### Scenario: Subscribing before a decision exists

- **WHEN** a subscriber registers on a first visit
- **THEN** it is called once the visitor decides, not before
