package app

import (
	"github.com/labstack/echo/v5"

	"__MODULE__/internal/blog"
	"__MODULE__/internal/handlers"
)

// This file is the whole of the blog's wiring. It exists only when the Blog
// addon is installed, and deleting it (with internal/blog/ and the two page
// templates) removes the blog completely.
//
// It is a separate file on purpose: installing the blog into an existing
// project then never has to rewrite router.go, which projects edit by hand and
// gosite sync deliberately preserves.
func init() {
	mountFeatures = append(mountFeatures, func(e *echo.Echo, h *handlers.Handlers) {
		blog.Mount(e, h)
	})
}
