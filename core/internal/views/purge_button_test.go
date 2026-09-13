package views

import (
	"bytes"
	"strings"
	"testing"
)

// The purge button posts without a token, which the endpoint accepts only in
// development. In production it must not be on the page at all.
func TestPurgeButtonIsDevelopmentOnly(t *testing.T) {
	r := NewRenderer("/storage/uploads")

	for _, tc := range []struct{ isDev, want bool }{{true, true}, {false, false}} {
		var buf bytes.Buffer
		err := r.Page(&buf, "home", map[string]any{
			"Title": "t", "Content": map[string]any{}, "IsDev": tc.isDev,
		})
		if err != nil {
			t.Fatal(err)
		}
		got := strings.Contains(buf.String(), "/cache/purge")
		if got != tc.want {
			t.Errorf("IsDev=%v: button present=%v, want %v", tc.isDev, got, tc.want)
		}
	}
}
