// Package addon is the registry of gosite addons' application halves.
//
// An addon's Cockpit half ships in the CMS image; its Go half lives in this
// module and registers itself here. A site enables addons by name in
// gosite.yml, and nothing of the addon is copied into the site.
package addon

import (
	"fmt"
	"io/fs"
	"slices"
	"strings"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
)

// Library is every addon gosite ships, whether or not it has a Go half.
// Analytics' application half is core itself; Forms, Replica and Webapp are
// Cockpit-only.
var Library = []string{"Analytics", "Blog", "Forms", "Replica", "Webapp"}

// Addon is the Go half of one addon.
type Addon struct {
	Name string

	// Mount registers the addon's routes and purge hooks. It runs after core's
	// routes and before the site's, so a site route still wins.
	Mount func(e *echo.Echo, h *handlers.Handlers)

	// Pages are the addon's default page templates (pages/*.html). A theme
	// page with the same file name replaces one.
	Pages fs.FS
}

var registry = map[string]Addon{}

// Register records an addon's Go half. Called from the addon package's init.
func Register(a Addon) {
	if !slices.Contains(Library, a.Name) {
		panic("addon: " + a.Name + " is not in the library")
	}
	registry[a.Name] = a
}

// Resolve returns the Go halves of the named addons, in the order given.
// Names are matched case-insensitively. A name gosite does not ship is an
// error; a library addon without a Go half is valid and contributes nothing.
func Resolve(names []string) ([]Addon, error) {
	var out []Addon
	for _, name := range names {
		canonical, ok := canonicalName(name)
		if !ok {
			return nil, fmt.Errorf("unknown addon %q; gosite's addons are: %s", name, strings.Join(Library, ", "))
		}
		if a, ok := registry[canonical]; ok {
			out = append(out, a)
		}
	}
	return out, nil
}

func canonicalName(name string) (string, bool) {
	for _, n := range Library {
		if strings.EqualFold(n, strings.TrimSpace(name)) {
			return n, true
		}
	}
	return "", false
}
