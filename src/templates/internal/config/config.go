// Package config reads every environment-provided setting exactly once.
package config

import (
	"fmt"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	Port           string
	RedisURL       string
	MongoURI       string
	MongoDB        string
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
}

func Load() Config {
	return Config{
		Port:       env("PORT", "8080"),
		RedisURL:   env("REDIS_URL", "redis://__REDIS_HOST__:__REDIS_PORT__/0"),
		MongoURI:   buildMongoURI(),
		MongoDB:    env("MONGO_DB", "__PROJECT__"),
		CockpitURL: env("COCKPIT_URL", "http://__PROJECT__-cms:80"),
		// Trimmed: a secret pasted into a deployment UI often arrives with a
		// trailing newline, and an untrimmed compare then fails against a CMS
		// that trimmed it (or did not) - a 401 with both sides "clearly" set to
		// the same value.
		CockpitToken:   strings.TrimSpace(os.Getenv("COCKPIT_API_TOKEN")),
		Environment:    os.Getenv("APP_ENV"),
		StorageAdapter: env("STORAGE_ADAPTER", "local"),
		S3PublicURL:    os.Getenv("S3_PUBLIC_URL"),
		SiteURL:        strings.TrimRight(os.Getenv("SITE_URL"), "/"),
	}
}

// buildMongoURI builds the MongoDB connection URI from its parts, matching
// cockpit/config.php: credentials are only included when both MONGO_USER and
// MONGO_PASSWORD are set (the shared gosite-mongo runs without auth), so an
// empty user:pass@ never reaches the driver. MONGO_URI, when set, wins.
func buildMongoURI() string {
	if v := os.Getenv("MONGO_URI"); v != "" {
		return v
	}
	host := env("MONGO_HOST", "gosite-mongo")
	port := env("MONGO_PORT", "27017")
	user := os.Getenv("MONGO_USER")
	pass := os.Getenv("MONGO_PASSWORD")
	if user != "" && pass != "" {
		return fmt.Sprintf("mongodb://%s:%s@%s:%s",
			url.PathEscape(user), url.PathEscape(pass), host, port)
	}
	return fmt.Sprintf("mongodb://%s:%s", host, port)
}

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
