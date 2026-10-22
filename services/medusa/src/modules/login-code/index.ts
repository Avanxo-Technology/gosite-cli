import { Module } from "@medusajs/framework/utils"

import LoginCodeModuleService from "./service"

// The codes a buyer signs in with: sent to their address, typed on the site.
// See lib/login-code and api/store/gosite/login-code.
export const LOGIN_CODE_MODULE = "loginCode"

export default Module(LOGIN_CODE_MODULE, {
  service: LoginCodeModuleService,
})
