# gosite-medusa: the pinned Medusa v2 image, built from services/medusa/.
# One image serves every store; the store's data comes from its compose file.
#
# Medusa v2 builds the runnable server into .medusa/server (config and src
# compiled to JS). Production runs from that output, not from the TypeScript
# sources: the runtime image has no ts-node, which is a build-time tool.
FROM node:22-bookworm-slim AS builder
WORKDIR /app
ENV NODE_ENV=production
# npm ci installs exactly the committed lockfile: two builds of one version
# get the same dependencies.
COPY package.json package-lock.json ./
RUN npm ci --include=dev
COPY . .
RUN npm run build

FROM node:22-bookworm-slim AS runtime
WORKDIR /app
# The medusa CLI lives in node_modules/.bin; the entrypoint calls it by name.
ENV NODE_ENV=production \
    PATH=/app/node_modules/.bin:$PATH
# Install runtime dependencies from the compiled server's package.json.
COPY --from=builder /app/.medusa/server/package.json /app/.medusa/server/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
# Then the compiled server itself, including medusa-config.js.
COPY --from=builder /app/.medusa/server/ ./
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /run/gosite-commerce
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
