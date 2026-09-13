// Command __PROJECT__ is a gosite site: Go + Cockpit CMS, server-rendered HTML
// with htmx and Alpine.js.
//
// The core - CMS client, page cache, SEO, analytics, consent, purge - is the
// gosite module in go.mod, not code in this repository. Upgrading it is
// changing that version. This site's own code is site/ and theme/.
package main

import (
	"embed"
	"io/fs"
	"os"

	"github.com/Avanxo-Technology/gosite-cli/core"

	"__MODULE__/site"
)

// The theme is embedded so the binary carries its templates.
//
//go:embed theme
var themeFS embed.FS

func theme() fs.FS {
	sub, err := fs.Sub(themeFS, "theme")
	if err != nil {
		panic(err)
	}
	return sub
}

func main() {
	if err := gosite.Run(site.New(), gosite.WithTheme(theme())); err != nil {
		os.Exit(1)
	}
}
