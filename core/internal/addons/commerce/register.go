// Package commerce is registered here as the Commerce addon: its Go half
// (Mount) and its default pages.
package commerce

import (
	"embed"
	"io/fs"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/addon"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
)

// pages are the storefront's default templates. A theme replaces any by
// shipping pages/<name>.html of the same name.
//
//go:embed pages/*.html
var pages embed.FS

// Pages exposes the addon's default templates for tooling and site tests
// (gositetest renders them). A theme replaces any by name.
func Pages() fs.FS { return pages }

func init() {
	addon.Register(addon.Addon{
		Name:      "Commerce",
		Configure: Configure,
		Mount:     func(e *echo.Echo, h *handlers.Handlers) { Mount(e, h) },
		Pages:     fs.FS(pages),
	})
}
