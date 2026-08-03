# syntax=docker/dockerfile:1

# --- stage 1: build ----------------------------------------------------------
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates
WORKDIR /src

# Dependencies first so the module cache survives source-only changes.
COPY go.mod go.sum* ./
RUN go mod download

# Templ codegen must run before the compiler sees the package. The CLI is
# pinned to the same version as the library so generated code always matches.
RUN go install github.com/a-h/templ/cmd/templ@v0.2.793

COPY . .
RUN templ generate

# CGO_ENABLED=0 produces a fully static binary that runs on a bare alpine.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath -ldflags="-s -w" \
      -o /out/app .

# --- stage 2: runtime --------------------------------------------------------
FROM alpine:latest

RUN apk add --no-cache ca-certificates tzdata wget \
 && adduser -D -u 10001 app

WORKDIR /app
COPY --from=builder /out/app /app/app
COPY --from=builder /src/static /app/static

USER app
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/app"]
