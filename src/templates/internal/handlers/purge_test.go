package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"
)

func purgeRequest(t *testing.T, body string) (model, id, scope string) {
	t.Helper()

	e := echo.New()
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(http.MethodPost, "/cache/purge", nil)
	} else {
		req = httptest.NewRequest(http.MethodPost, "/cache/purge", strings.NewReader(body))
	}
	c := e.NewContext(req, httptest.NewRecorder())
	return purgeTarget(c)
}

// Cockpit's Settings -> Clear cache has no model to name: after that flush no
// cached page can be trusted, so it says so with scope instead.
func TestPurgeScopeAll(t *testing.T) {
	_, _, scope := purgeRequest(t, `{"scope":"all"}`)
	if scope != "all" {
		t.Fatalf("scope = %q, want all", scope)
	}
}

// The on-page button sends no body, and so does a CMS older than this app.
// Neither may be read as "purge everything".
func TestPurgeWithoutBodyNamesNothing(t *testing.T) {
	for _, body := range []string{"", "{}", "not json"} {
		model, id, scope := purgeRequest(t, body)
		if model != "" || id != "" || scope != "" {
			t.Errorf("body %q yielded model=%q id=%q scope=%q, want all empty", body, model, id, scope)
		}
	}
}

func TestPurgeNamesModelAndID(t *testing.T) {
	model, id, scope := purgeRequest(t, `{"model":"blogPosts","id":"abc123"}`)
	if model != "blogPosts" || id != "abc123" {
		t.Errorf("model=%q id=%q", model, id)
	}
	if scope != "" {
		t.Errorf("a named model must not also claim a scope, got %q", scope)
	}
}

// A model in the layout invalidates every page; one that is not, does not.
func TestSiteWideModels(t *testing.T) {
	for _, m := range []string{"webapp", "seoPages", "analyticsIntegrations"} {
		if !isSiteWide(m) {
			t.Errorf("%s is rendered by the layout and must be site-wide", m)
		}
	}
	for _, m := range []string{"", "blogPosts", "home"} {
		if isSiteWide(m) {
			t.Errorf("%q must not purge the whole site", m)
		}
	}
}
