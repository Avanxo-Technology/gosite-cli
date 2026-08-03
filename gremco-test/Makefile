.PHONY: dev generate build tidy

dev:      ## Hot reload on the host (containers: use `gosite start`)
	air -c .air.toml

generate: ## Regenerate Templ components
	templ generate

build: generate
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ./tmp/app .

tidy:
	go mod tidy
