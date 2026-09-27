package gositetest

import (
	"testing"
	"testing/fstest"
)

func TestCommercePagesRenderWithDefaultTheme(t *testing.T) {
	CheckCommercePages(t, nil)
}

func TestCommercePagesHonourAThemeOverride(t *testing.T) {
	theme := fstest.MapFS{
		"layout.html":             {Data: []byte(okLayout)},
		"pages/commerce-pdp.html": {Data: []byte(`{{define "content"}}override{{end}}`)},
	}
	CheckCommercePages(t, theme)
}
