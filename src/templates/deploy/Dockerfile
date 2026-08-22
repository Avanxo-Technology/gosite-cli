# syntax=docker/dockerfile:1

# --- stage 1: build ----------------------------------------------------------
FROM golang:1.26-alpine AS builder

ARG GO_BUILD_CPUS=2

RUN apk add --no-cache git ca-certificates
WORKDIR /src

# Dependencies first so the module cache survives source-only changes.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 produces a fully static binary that runs on a bare alpine.
# GOMAXPROCS + -p limit parallel compilation to 2 CPUs so the build does not
# saturate a 6-core server. Override with GO_BUILD_CPUS=6 in Coolify if needed.
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=${GO_BUILD_CPUS} go build -p=${GO_BUILD_CPUS} \
      -trimpath -ldflags="-s -w" \
      -o /out/app ./cmd/server

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
