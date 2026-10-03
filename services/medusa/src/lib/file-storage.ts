import { Agent } from "node:https"

// Product images go to the site's own bucket, with the same S3_* variables the
// CMS reads, so each environment (dev MinIO, QA, prod) uploads to the bucket
// its compose file names. Without them Medusa falls back to its local provider,
// which writes inside the container (lost on every redeploy) and answers with a
// localhost URL - so a store without S3 should not take uploads.

export type Env = Record<string, string | undefined>

// The folder under the site's prefix: keeps Medusa's files apart from the
// CMS's uploads in a shared bucket.
const FOLDER = "medusa"

export function s3FileModule(env: Env): Record<string, unknown> | null {
  const bucket = env.S3_BUCKET?.trim()
  const key = env.S3_KEY?.trim()
  const secret = env.S3_SECRET?.trim()
  const publicURL = env.S3_PUBLIC_URL?.trim()
  if (env.STORAGE_ADAPTER?.trim() !== "s3" || !bucket || !key || !secret) {
    return null
  }
  if (!publicURL) {
    // Every product page would point at a URL nobody can open.
    throw new Error("S3_PUBLIC_URL is required when STORAGE_ADAPTER=s3 (the public base URL of S3_BUCKET)")
  }

  const clientConfig: Record<string, unknown> = {
    // MinIO and most S3-compatible servers address buckets by path.
    forcePathStyle: true,
  }
  if (env.S3_VERIFY?.trim() === "false") {
    // dev MinIO uses a mkcert certificate the container does not trust; same
    // switch the CMS honours. Never set in QA or prod.
    clientConfig.requestHandler = { httpsAgent: new Agent({ rejectUnauthorized: false }) }
  }

  const options: Record<string, unknown> = {
    file_url: publicURL.replace(/\/+$/, ""),
    access_key_id: key,
    secret_access_key: secret,
    region: env.S3_REGION?.trim() || "us-east-1",
    bucket,
    endpoint: env.S3_URL?.trim() || undefined,
    prefix: s3Prefix(env.S3_PREFIX),
    additional_client_config: clientConfig,
  }
  const acl = env.S3_ACL?.trim()
  if (acl) {
    options.acl = acl
  }

  return {
    resolve: "@medusajs/medusa/file",
    options: {
      providers: [{ resolve: "@medusajs/medusa/file-s3", id: "s3", options }],
    },
  }
}

// s3Prefix joins the site's S3_PREFIX and Medusa's folder: "" -> "medusa/",
// "aldu" or "aldu/" -> "aldu/medusa/".
export function s3Prefix(sitePrefix: string | undefined): string {
  const base = (sitePrefix ?? "").trim().replace(/^\/+|\/+$/g, "")
  return base ? `${base}/${FOLDER}/` : `${FOLDER}/`
}
