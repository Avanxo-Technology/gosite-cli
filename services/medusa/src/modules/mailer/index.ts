import { Module } from "@medusajs/framework/utils"

import MailerModuleService from "./service"

// gosite's mailer: e-mails on store events, with rules and HTML templates
// edited in the Admin (Mailer). See lib/mailer and subscribers/mailer.
export const MAILER_MODULE = "mailer"

export default Module(MAILER_MODULE, {
  service: MailerModuleService,
})
