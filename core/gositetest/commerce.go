package gositetest

import (
	"bytes"
	"io/fs"
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/addons/commerce"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// CommercePages are the pages and fragments the Commerce addon ships. A site
// test names one when it wants to check a single override.
var CommercePages = []string{
	"commerce-plp",
	"commerce-pdp",
	"commerce-buy",
	"commerce-cart",
	"commerce-cart-lines",
	"commerce-minicart",
	"commerce-checkout",
	"commerce-confirmation",
	"commerce-step-email",
	"commerce-step-shipping",
	"commerce-step-payment",
	"commerce-pay-stripe",
	"commerce-pay-wompi",
	"commerce-payment-status",
	"commerce-address",
	"commerce-address-co",
	"commerce-address-us",
}

// CheckCommercePages renders every commerce page with the given theme (or core's
// default when theme is nil), so a theme that breaks one fails in the site's own
// tests instead of at the first request. A theme overrides a commerce page by
// shipping `pages/<name>.html`.
//
// The pages must render with empty data: that is the same contract core probes
// at startup, and it is what lets a page without a product still answer.
func CheckCommercePages(t testing.TB, theme fs.FS) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("commerce pages failed to render: %v", r)
		}
	}()

	opts := []views.Option{views.WithPages(commerce.Pages())}
	if theme != nil {
		opts = append(opts, views.WithTheme(theme))
	}
	renderer := views.NewRenderer("", opts...)

	for _, name := range CommercePages {
		var buf bytes.Buffer
		if err := renderer.Page(&buf, name, map[string]any{}); err != nil {
			t.Errorf("commerce page %q failed to render: %v", name, err)
		}
	}
}
