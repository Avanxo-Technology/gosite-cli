// Package config reads every environment-provided setting exactly once.
package config

import (
	"os"
	"strings"
)

type Config struct {
	// Project is the gosite project name (GOSITE_PROJECT). It namespaces every
	// Redis key and names the CMS service, so it must be unique per shared Redis.
	Project        string
	Port           string
	RedisURL       string
	CockpitURL     string
	CockpitToken   string
	Environment    string
	StorageAdapter string
	S3PublicURL    string

	// SiteURL is the site's own public origin, e.g. https://example.com. Used
	// to build absolute URLs a page cannot infer from the request alone -
	// canonical links and Open Graph tags, which crawlers require absolute.
	// Empty is allowed: those tags are then omitted rather than emitted wrong.
	SiteURL string

	// BasicAuth is "user:password" from HTTP_BASIC_CREDENTIALS. When set, every
	// route except /healthz, /cache/purge and /robots.txt requires it, and the
	// site asks crawlers not to index it. Empty (or without a colon) leaves the
	// site public. Read from the environment of each deployment, never a file.
	BasicAuth string
}

func Load() Config {
	project := env("GOSITE_PROJECT", "gosite")
	return Config{
		Project:    project,
		Port:       env("PORT", "8080"),
		RedisURL:   env("REDIS_URL", "redis://gosite-redis:6379/0"),
		CockpitURL: env("COCKPIT_URL", "http://"+project+"-cms:80"),
		// Trimmed: a secret pasted into a deployment UI often arrives with a
		// trailing newline, and an untrimmed compare then fails against a CMS
		// that trimmed it (or did not) - a 401 with both sides "clearly" set to
		// the same value.
		CockpitToken:   strings.TrimSpace(os.Getenv("COCKPIT_API_TOKEN")),
		Environment:    os.Getenv("APP_ENV"),
		StorageAdapter: env("STORAGE_ADAPTER", "local"),
		S3PublicURL:    os.Getenv("S3_PUBLIC_URL"),
		SiteURL:        strings.TrimRight(os.Getenv("SITE_URL"), "/"),
		BasicAuth:      strings.TrimSpace(os.Getenv("HTTP_BASIC_CREDENTIALS")),
	}
}

// CacheKeyPrefix is the only Redis prefix a purge may sweep. It includes the
// environment when APP_ENV is set, so production and QA sharing one Redis
// never read or purge each other's pages. With APP_ENV empty it is the
// project-only prefix, as before this change.
func (c Config) CacheKeyPrefix() string {
	if c.Environment == "" {
		return c.Project + ":cache:"
	}
	return c.Project + ":" + c.Environment + ":cache:"
}

// StateKeyPrefix holds application state. Nothing purges it.
func (c Config) StateKeyPrefix() string { return c.Project + ":app:" }

// AssetBaseURL is the base used to build browser-reachable URLs for CMS asset
// paths. With S3 storage the assets live on a public bucket/endpoint, so the
// page points at it directly (CDN-style) instead of proxying through this app.
// Without S3 the base is the local /storage/uploads mount that router.go serves.
func (c Config) AssetBaseURL() string {
	if c.StorageAdapter == "s3" && strings.TrimSpace(c.S3PublicURL) != "" {
		return strings.TrimRight(c.S3PublicURL, "/")
	}
	return "/storage/uploads"
}

// IsDev reports whether the app is running for development. In dev mode the
// cache-purge button skips token authentication.
func (c Config) IsDev() bool {
	switch c.Environment {
	case "development", "dev", "local":
		return true
	default:
		return false
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
