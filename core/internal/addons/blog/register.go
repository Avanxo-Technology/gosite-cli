package blog

import (
	"embed"
	"io/fs"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/addon"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
)

// pages are the blog's default templates. A theme replaces either by shipping
// pages/blog-index.html or pages/blog-article.html.
//
//go:embed pages/*.html
var pages embed.FS

func init() {
	addon.Register(addon.Addon{
		Name:  "Blog",
		Mount: func(e *echo.Echo, h *handlers.Handlers) { Mount(e, h) },
		Pages: fs.FS(pages),
	})
}
