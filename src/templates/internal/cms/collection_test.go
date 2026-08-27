package cms

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"__MODULE__/internal/config"
)

func newTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *[]url.Values) {
	t.Helper()
	var seen []url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.URL.Query())
		handler(w, r)
	}))
	t.Cleanup(srv.Close)
	return New(config.Config{CockpitURL: srv.URL}, slog.Default()), &seen
}

// The wrapper shape must decode to items plus the exact total.
func TestItemsWrapperShape(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{{"_id": "a"}, {"_id": "b"}},
			"meta": map[string]any{"total": 7},
		})
	})

	res, err := c.Items(context.Background(), "blogPosts", Query{Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Items) != 2 || res.Items[0]["_id"] != "a" {
		t.Fatalf("items = %v", res.Items)
	}
	if res.Total != 7 {
		t.Errorf("total = %d, want 7", res.Total)
	}
	if !res.HasMore {
		t.Error("HasMore = false, want true (2 of 7)")
	}
}

// A bare array must not be mistaken for anything else, and must not error.
func TestItemsBareArrayShape(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode([]map[string]any{{"_id": "a"}})
	})

	res, err := c.Items(context.Background(), "blogPosts", Query{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Items) != 1 || res.Items[0]["_id"] != "a" {
		t.Fatalf("items = %v", res.Items)
	}
	if res.HasMore {
		t.Error("HasMore = true on a short bare array")
	}
}

// The trap that bit Replica: the wrapper read as a list yields entries with no
// _id. Every item we hand back must carry one.
func TestWrapperIsNeverReadAsList(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{{"_id": "a"}},
			"meta": map[string]any{"total": 1},
		})
	})

	res, err := c.Items(context.Background(), "blogPosts", Query{Limit: 5})
	if err != nil {
		t.Fatal(err)
	}
	for i, item := range res.Items {
		if item["_id"] == nil {
			t.Fatalf("item %d has no _id: %v", i, item)
		}
	}
}

// skip and limit must always travel, so the shape is deterministic.
func TestSkipAndLimitAlwaysSent(t *testing.T) {
	c, seen := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}, "meta": map[string]any{"total": 0}})
	})

	if _, err := c.Items(context.Background(), "blogPosts", Query{}); err != nil {
		t.Fatal(err)
	}
	q := (*seen)[0]
	if q.Get("skip") == "" || q.Get("limit") == "" {
		t.Fatalf("skip/limit missing: %v", q)
	}
}

// filter and sort are JSON strings, not nested query parameters.
func TestFilterAndSortAreJSON(t *testing.T) {
	c, seen := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}, "meta": map[string]any{"total": 0}})
	})

	_, err := c.Items(context.Background(), "blogPosts", Query{
		Filter: map[string]any{"slug": "mi-post"},
		Sort:   map[string]int{"publishedAt": -1},
	})
	if err != nil {
		t.Fatal(err)
	}
	q := (*seen)[0]
	if q.Get("filter") != `{"slug":"mi-post"}` {
		t.Errorf("filter = %q", q.Get("filter"))
	}
	if q.Get("sort") != `{"publishedAt":-1}` {
		t.Errorf("sort = %q", q.Get("sort"))
	}
}

// Paging still works when the CMS reports no total.
func TestPagingWithoutTotal(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{{"_id": "a"}, {"_id": "b"}},
			"meta": map[string]any{},
		})
	})

	res, err := c.Items(context.Background(), "blogPosts", Query{Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	if res.Total != -1 {
		t.Errorf("total = %d, want -1 (unknown)", res.Total)
	}
	if !res.HasMore {
		t.Error("a full page with no total should report HasMore")
	}
}

// An empty collection is not an error.
func TestEmptyIsNotAnError(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}, "meta": map[string]any{"total": 0}})
	})

	res, err := c.Items(context.Background(), "blogPosts", Query{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Items) != 0 || res.HasMore {
		t.Fatalf("res = %+v", res)
	}
}

// A failed read must be distinguishable from an empty one, so the caller can
// discard the render instead of caching an empty page.
func TestFailedReadReturnsError(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	})

	if _, err := c.Items(context.Background(), "blogPosts", Query{Limit: 10}); err == nil {
		t.Fatal("expected an error for a 502")
	}
}

// First returns nil, not an error, when nothing matches.
func TestFirstMissingIsNotAnError(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}, "meta": map[string]any{"total": 0}})
	})

	item, err := c.First(context.Background(), "blogPosts", map[string]any{"slug": "nope"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if item != nil {
		t.Fatalf("item = %v, want nil", item)
	}
}
