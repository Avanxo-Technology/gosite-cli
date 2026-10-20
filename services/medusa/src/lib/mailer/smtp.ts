// SMTP settings from the same variables the CMS reads (cockpit/config.php), so
// one set of credentials in Coolify serves the CMS and the store. Pure: the
// subscriber turns these into a nodemailer transport.

export interface SMTPSettings {
  host: string
  port: number
  // nodemailer's secure: implicit TLS (SMTP_ENCRYPTION=ssl, port 465).
  secure: boolean
  // STARTTLS is required (tls) or skipped (none).
  requireTLS: boolean
  ignoreTLS: boolean
  auth?: { user: string; pass: string }
  from: string
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

// smtpSettings returns undefined when SMTP_HOST is unset, or when there is no
// sender (SMTP_FROM, or SMTP_USER when it is an address): providers reject an
// empty MAIL FROM. Without settings the mailer records the e-mail as skipped.
export function smtpSettings(env: Record<string, string | undefined>): SMTPSettings | undefined {
  const host = env.SMTP_HOST?.trim()
  if (!host) {
    return undefined
  }
  const port = Number.parseInt(env.SMTP_PORT ?? "", 10) || 587
  const encryption = (env.SMTP_ENCRYPTION || (port === 465 ? "ssl" : "tls")).toLowerCase()
  const user = env.SMTP_USER ?? ""
  const address = env.SMTP_FROM || (EMAIL.test(user) ? user : "")
  if (!address) {
    return undefined
  }
  const name = env.SMTP_FROM_NAME?.trim()
  return {
    host,
    port,
    secure: encryption === "ssl",
    requireTLS: encryption === "tls",
    ignoreTLS: encryption === "none",
    auth: user ? { user, pass: env.SMTP_PASSWORD ?? "" } : undefined,
    from: name ? `"${name.replace(/"/g, "'")}" <${address}>` : address,
  }
}
