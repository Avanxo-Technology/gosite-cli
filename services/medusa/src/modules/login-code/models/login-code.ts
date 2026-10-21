import { model } from "@medusajs/framework/utils"

// One code sent to an address. Only its hash is kept: the code itself is in
// the e-mail and nowhere else.
export const LoginCode = model.define("login_code", {
  id: model.id({ prefix: "lcode" }).primaryKey(),
  email: model.text().index(),
  code_hash: model.text(),
  expires_at: model.dateTime(),
  // Wrong codes typed against this one; at MAX_VERIFY_ATTEMPTS it is spent.
  attempts: model.number().default(0),
  // Set once the code signed someone in, or a newer code replaced it.
  consumed_at: model.dateTime().nullable(),
})
