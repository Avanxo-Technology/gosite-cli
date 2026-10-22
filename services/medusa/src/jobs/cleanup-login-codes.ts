import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

import { LOGIN_CODE_MODULE } from "../modules/login-code"
import type LoginCodeModuleService from "../modules/login-code/service"

// Daily removal of sign-in codes older than a day: past their ten minutes and
// the hour the resend limit reads, nothing needs them.
export const config = {
  name: "cleanup-login-codes",
  schedule: "15 3 * * *",
}

export default async function cleanupLoginCodes(container: MedusaContainer) {
  const codes: LoginCodeModuleService = container.resolve(LOGIN_CODE_MODULE)
  const cutoff = new Date(Date.now() - 24 * 3_600_000)
  let deleted = 0
  for (;;) {
    const old = await codes.listLoginCodes({ created_at: { $lt: cutoff } }, { select: ["id"], take: 500 })
    if (!old.length) {
      break
    }
    await codes.deleteLoginCodes(old.map((c) => c.id))
    deleted += old.length
  }
  if (deleted) {
    container.resolve(ContainerRegistrationKeys.LOGGER).info(`cleanup-login-codes: deleted ${deleted} code(s)`)
  }
}
