package commerce

import (
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/siteconfig"
)

// Package state, set once by Configure before Mount and read by every handler.
// A process is one site (design D1), so package state is per-site state.
var (
	cfgRegion       = ""
	cfgPLPPath      = DefaultPLPPath
	cfgPDPPath      = DefaultPDPPath
	cfgCheckoutPath = DefaultCheckoutPath
)

// Defaults for the flat commerce_* keys of gosite.yml (design D4).
const (
	DefaultPLPPath      = "/tienda"
	DefaultPDPPath      = "/producto"
	DefaultCheckoutPath = "/checkout"

	envBaseURL = "COMMERCE_URL"
)

// SupportedRegions are the seed's regions; Configure rejects anything else.
var SupportedRegions = []string{"co", "us"}

// validPath is a store path: lowercase segments, no trailing slash, and none
// of Echo's ":param" or "*" syntax, which would turn it into a pattern.
var validPath = regexp.MustCompile(`^/[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)*$`)

// reservedPaths are served by the core or by this addon; a store path equal to
// one of them, or under one, would shadow it.
var reservedPaths = []string{
	"/_commerce", cartPath, "/cache", "/healthz", "/static",
	"/robots.txt", "/sitemap.xml", "/llms.txt", "/favicon.ico",
}

// Configure validates the commerce_* keys and applies them. It runs before any
// route is mounted, so a rejected value stops startup with the key named
// (addon-config spec). Only keys prefixed commerce_ are read.
func Configure(sc siteconfig.Config) error {
	// No default: a store started in the wrong currency cannot be fixed later,
	// because the seed never edits a region that exists.
	region := strings.ToLower(strings.TrimSpace(sc.Values["commerce_region"]))
	if region == "" {
		return fmt.Errorf("commerce_region is required; accepted values: %s", strings.Join(SupportedRegions, ", "))
	}
	if !slices.Contains(SupportedRegions, region) {
		return fmt.Errorf("commerce_region %q is not supported; accepted values: %s", region, strings.Join(SupportedRegions, ", "))
	}

	paths := []struct {
		key   string
		value string
	}{
		{"commerce_plp_path", valueOr(sc, "commerce_plp_path", DefaultPLPPath)},
		{"commerce_pdp_path", valueOr(sc, "commerce_pdp_path", DefaultPDPPath)},
		{"commerce_checkout_path", valueOr(sc, "commerce_checkout_path", DefaultCheckoutPath)},
	}
	seen := map[string]string{}
	for _, p := range paths {
		if !validPath.MatchString(p.value) {
			return fmt.Errorf("%s must be a path like /tienda (lowercase letters, digits and -, no trailing /), got %q", p.key, p.value)
		}
		for _, reserved := range reservedPaths {
			if p.value == reserved || strings.HasPrefix(p.value, reserved+"/") {
				return fmt.Errorf("%s %q would shadow %s, which gosite already serves", p.key, p.value, reserved)
			}
		}
		if other, ok := seen[p.value]; ok {
			return fmt.Errorf("%s and %s have the same value %q", other, p.key, p.value)
		}
		seen[p.value] = p.key
	}

	// Commit only after every check passed: a rejected config leaves the
	// package on its previous (default) values.
	cfgRegion = region
	cfgPLPPath = paths[0].value
	cfgPDPPath = paths[1].value
	cfgCheckoutPath = paths[2].value
	return nil
}

// BaseURL is the commerce service address. The generated compose sets
// COMMERCE_URL for the site container; the default is the project-network name
// (design D2).
func BaseURL() string {
	if url := strings.TrimSpace(os.Getenv(envBaseURL)); url != "" {
		return url
	}
	return DefaultBaseURL
}

// currentRegion is the only region source (design D4): handlers, cart creation
// and cache keys call this and nothing else, so multi-region later changes one
// function.
func currentRegion() string { return cfgRegion }

// valueOr returns the trimmed value of a gosite.yml key, or fallback.
func valueOr(sc siteconfig.Config, key, fallback string) string {
	if v, ok := sc.Values[key]; ok {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return fallback
}
