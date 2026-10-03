import { defineConfig, loadEnv } from "@medusajs/framework/utils"

import { s3FileModule } from "./src/lib/file-storage"

loadEnv(process.env.NODE_ENV || "development", process.cwd())

const REDIS_URL = process.env.REDIS_URL

// Every store is its own Medusa (design D1). The database, the admin secrets
// and the region come from the site's generated compose file; nothing is
// hardcoded here so QA and prod can never point at the same database.
//
// Payment providers are registered from credentials (design D1 of the payments
// change): manual always, Stripe when STRIPE_API_KEY is set, Wompi when its four
// keys are. Enablement per region stays a decision in Medusa Admin.
const paymentProviders: Record<string, unknown>[] = []

if (process.env.STRIPE_API_KEY) {
  paymentProviders.push({
    resolve: "@medusajs/medusa/payment-stripe",
    id: "stripe",
    options: { apiKey: process.env.STRIPE_API_KEY },
  })
}

const wompi = {
  publicKey: process.env.WOMPI_PUBLIC_KEY,
  privateKey: process.env.WOMPI_PRIVATE_KEY,
  integritySecret: process.env.WOMPI_INTEGRITY_SECRET,
  eventsSecret: process.env.WOMPI_EVENTS_SECRET,
}
if (wompi.publicKey && wompi.privateKey && wompi.integritySecret && wompi.eventsSecret) {
  paymentProviders.push({
    resolve: "./src/modules/wompi",
    id: "wompi",
    options: {
      ...wompi,
      checkoutURL: process.env.WOMPI_CHECKOUT_URL,
      baseURL: process.env.WOMPI_API_URL,
    },
  })
}

const modules: Record<string, unknown>[] = [
  {
    resolve: "@medusajs/medusa/caching",
    options: {
      providers: [
        {
          resolve: "@medusajs/medusa/caching-redis",
          id: "caching-redis",
          is_default: true,
          options: { redisUrl: REDIS_URL },
        },
      ],
    },
  },
  {
    resolve: "@medusajs/medusa/event-bus-redis",
    options: { redisUrl: REDIS_URL },
  },
  {
    resolve: "@medusajs/medusa/workflow-engine-redis",
    // The loader still reads redis.url; the deprecation warning about redisUrl
    // is not honoured by this Medusa version.
    options: { redis: { url: REDIS_URL } },
  },
  {
    resolve: "@medusajs/medusa/locking",
    options: {
      providers: [
        {
          resolve: "@medusajs/medusa/locking-redis",
          id: "locking-redis",
          is_default: true,
          options: { redisUrl: REDIS_URL },
        },
      ],
    },
  },
]

// Uploads (product images from the Admin or the API) go to the site's bucket.
const fileModule = s3FileModule(process.env)
if (fileModule) {
  modules.push(fileModule)
}

if (paymentProviders.length) {
  modules.push({
    resolve: "@medusajs/medusa/payment",
    options: { providers: paymentProviders },
  })
}

export default defineConfig({
  projectConfig: {
    databaseUrl: process.env.DATABASE_URL,
    redisUrl: REDIS_URL,
    http: {
      jwtSecret: process.env.JWT_SECRET,
      cookieSecret: process.env.COOKIE_SECRET,
      // The Store API is reachable only from the site container over the
      // project network: no browser origin needs it, so none is allowed. The
      // Admin is served on the shop.<site> subdomain.
      storeCors: "",
      adminCors: process.env.ADMIN_CORS || "",
      authCors: process.env.AUTH_CORS || process.env.ADMIN_CORS || "",
    },
  },
  admin: {
    // `/app` is routed by Traefik; the admin API it calls lives under /admin.
    path: "/app",
  },
  modules,
})
