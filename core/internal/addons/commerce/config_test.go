package commerce

import (
	"strings"
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/siteconfig"
)

func resetConfig() {
	cfgRegion = "co"
	cfgPLPPath = DefaultPLPPath
	cfgPDPPath = DefaultPDPPath
	cfgCheckoutPath = DefaultCheckoutPath
}

func configWith(values map[string]string) siteconfig.Config {
	return siteconfig.Config{Values: values, Lists: map[string][]string{}}
}

func TestConfigureDefaults(t *testing.T) {
	resetConfig()
	if err := Configure(configWith(nil)); err != nil {
		t.Fatal(err)
	}
	if currentRegion() != "co" || cfgPLPPath != "/tienda" || cfgPDPPath != "/producto" || cfgCheckoutPath != "/checkout" {
		t.Fatalf("defaults = %q %q %q %q", currentRegion(), cfgPLPPath, cfgPDPPath, cfgCheckoutPath)
	}
}

func TestConfigureCustomPaths(t *testing.T) {
	resetConfig()
	err := Configure(configWith(map[string]string{
		"commerce_region":        "us",
		"commerce_plp_path":      "/shop",
		"commerce_pdp_path":      "/p",
		"commerce_checkout_path": "/pagar",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if currentRegion() != "us" || cfgPLPPath != "/shop" || cfgPDPPath != "/p" || cfgCheckoutPath != "/pagar" {
		t.Fatalf("configured = %q %q %q %q", currentRegion(), cfgPLPPath, cfgPDPPath, cfgCheckoutPath)
	}
}

func TestConfigureRejectsUnknownRegion(t *testing.T) {
	resetConfig()
	err := Configure(configWith(map[string]string{"commerce_region": "xx"}))
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "commerce_region") || !strings.Contains(err.Error(), "co, us") {
		t.Fatalf("err = %v, want the key and the accepted values", err)
	}
}

func TestConfigureRejectsRelativePath(t *testing.T) {
	resetConfig()
	err := Configure(configWith(map[string]string{"commerce_plp_path": "shop"}))
	if err == nil || !strings.Contains(err.Error(), "commerce_plp_path") {
		t.Fatalf("err = %v", err)
	}
}

func TestConfigureRejectsCollidingPaths(t *testing.T) {
	resetConfig()
	err := Configure(configWith(map[string]string{
		"commerce_plp_path": "/shop",
		"commerce_pdp_path": "/shop",
	}))
	if err == nil || !strings.Contains(err.Error(), "same value") {
		t.Fatalf("err = %v", err)
	}
}

// A rejected config must not half-apply: the defaults (or last good values)
// stay in place.
func TestConfigureLeavesStateOnRejection(t *testing.T) {
	resetConfig()
	if err := Configure(configWith(map[string]string{"commerce_region": "us"})); err != nil {
		t.Fatal(err)
	}
	_ = Configure(configWith(map[string]string{"commerce_plp_path": "bad"}))
	if currentRegion() != "us" || cfgPLPPath != DefaultPLPPath {
		t.Fatalf("state changed after a rejected config: %q %q", currentRegion(), cfgPLPPath)
	}
}

func TestBaseURL(t *testing.T) {
	t.Setenv("COMMERCE_URL", "")
	if got := BaseURL(); got != DefaultBaseURL {
		t.Fatalf("BaseURL() = %q, want %q", got, DefaultBaseURL)
	}
	t.Setenv("COMMERCE_URL", "http://shop-medusa:9000")
	if got := BaseURL(); got != "http://shop-medusa:9000" {
		t.Fatalf("BaseURL() = %q", got)
	}
}
