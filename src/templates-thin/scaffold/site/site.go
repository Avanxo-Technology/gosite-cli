// Package site is this site's own code: its routes and handlers.
//
// Everything a handler needs from core comes through the Router: CMS() for
// content, CachedRender() and Render() for pages, State() for application
// data. Core already serves /healthz, /robots.txt, /sitemap.xml, /llms.txt,
// /favicon.ico and POST /cache/purge; registering one of those paths here
// replaces core's.
package site

import (
	"context"
	"errors"

	"github.com/Avanxo-Technology/gosite-cli/core"
	"github.com/Avanxo-Technology/gosite-cli/core/cms"
)

// Site implements gosite.App. Add Middleware, TemplateData or OnPurge methods
// when the site needs them (see gosite.Middlewarer, TemplateDataer, Purger).
type Site struct{}

func New() *Site { return &Site{} }

// Routes registers the site's pages.
func (s *Site) Routes(r gosite.Router) {
	r.GET("/", func(c *gosite.Context) error {
		return r.CachedRender(c, "home", func(ctx context.Context) (gosite.Page, error) {
			content, err := r.CMS().SingletonErr(ctx, "home")
			// A "home" singleton nobody has created yet is not a broken site:
			// the page renders its own fallback text until an editor adds it.
			if errors.Is(err, cms.ErrNotFound) {
				content, err = nil, nil
			}
			return gosite.Page{Title: "__PROJECT__", Content: content}, err
		})
	})
}
