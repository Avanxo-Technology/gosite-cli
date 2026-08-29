package cache

import "testing"

// A purge must not remove the stale copies. They are what a failed re-render
// falls back on, and a purge is precisely when that happens: the CMS may still
// be rebuilding its model registry and answer 412, and without the fallback the
// visitor gets a 502 the moment somebody publishes.
func TestGroupPurgeKeepsStaleCopies(t *testing.T) {
	cases := []struct {
		key          string
		includeStale bool
		want         bool
	}{
		{"site:home_html", false, true},
		{"site:home_html:stale", false, false},
		{"site:blog:post:hello", false, true},
		{"site:blog:post:hello:stale", false, false},

		// PurgeGroupIncludingStale is the deliberate escape hatch.
		{"site:home_html", true, true},
		{"site:home_html:stale", true, true},
	}

	for _, tc := range cases {
		if got := purges(tc.key, tc.includeStale); got != tc.want {
			t.Errorf("purges(%q, includeStale=%v) = %v, want %v", tc.key, tc.includeStale, got, tc.want)
		}
	}
}

// staleKey and the suffix the purge filter matches on must not drift apart.
func TestStaleKeyMatchesSuffix(t *testing.T) {
	if purges(staleKey("site:home_html"), false) {
		t.Error("a key built by staleKey must be recognised as stale by the purge filter")
	}
}
