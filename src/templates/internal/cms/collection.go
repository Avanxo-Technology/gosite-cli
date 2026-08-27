package cms

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
)

// Query describes one collection read.
//
// Filter and Sort are sent as JSON: Cockpit decodes them server-side (json5),
// so they are strings on the wire, not nested query parameters. Fields is a
// projection - useful on an index page, where dragging every article body over
// the network to render a list of titles is pure waste.
type Query struct {
	Filter   map[string]any
	Sort     map[string]int
	Fields   map[string]int
	Skip     int
	Limit    int
	Populate int
}

// Result is one page of a collection.
//
// Total is the number of items matching the filter, not the size of this page.
// It is -1 when the CMS did not report one, which is why HasMore exists: paging
// has to work either way.
type Result struct {
	Items   []Content
	Total   int
	HasMore bool
}

// Items reads a page of a Cockpit collection.
//
// Skip and Limit are always sent, even when the caller wants everything. Two
// reasons, and they are the same reason: Cockpit returns a bare array normally
// but wraps the response as {data, meta} when skip AND limit are both present,
// and meta is the only place the total comes from. Forcing the wrapper makes
// the shape deterministic and hands back the total in one move.
//
// The decoder still accepts both shapes. The rule above is read off one Cockpit
// version and is not part of any documented contract, so a future change
// degrades instead of breaking.
//
// Unpublished entries are never returned: Cockpit's read endpoint overwrites
// filter._state with 1 after decoding whatever the caller sent. Drafts are
// invisible here by construction, not by our filtering.
func (c *Client) Items(ctx context.Context, model string, q Query) (Result, error) {
	if q.Limit <= 0 {
		q.Limit = 100
	}

	params := url.Values{}
	params.Set("skip", strconv.Itoa(q.Skip))
	params.Set("limit", strconv.Itoa(q.Limit))

	if q.Populate > 0 {
		params.Set("populate", strconv.Itoa(q.Populate))
	}
	if len(q.Filter) > 0 {
		encoded, err := json.Marshal(q.Filter)
		if err != nil {
			return Result{}, fmt.Errorf("encoding filter: %w", err)
		}
		params.Set("filter", string(encoded))
	}
	if len(q.Sort) > 0 {
		encoded, err := json.Marshal(q.Sort)
		if err != nil {
			return Result{}, fmt.Errorf("encoding sort: %w", err)
		}
		params.Set("sort", string(encoded))
	}
	if len(q.Fields) > 0 {
		encoded, err := json.Marshal(q.Fields)
		if err != nil {
			return Result{}, fmt.Errorf("encoding fields: %w", err)
		}
		params.Set("fields", string(encoded))
	}

	path := "/api/content/items/" + model + "?" + params.Encode()

	// Deduplicate identical concurrent reads the same way singletons are
	// deduplicated: a cold cache must not turn into N parallel Cockpit calls.
	v, err, _ := c.sf.Do("items:"+path, func() (any, error) {
		body, err := c.fetchRaw(ctx, path)
		if err != nil {
			return nil, err
		}
		return decodeItems(body)
	})
	if err != nil {
		return Result{}, err
	}

	result := v.(Result)
	result.HasMore = q.Skip+len(result.Items) < result.Total
	if result.Total < 0 {
		// No total to compare against: a full page means there may be another.
		result.HasMore = len(result.Items) == q.Limit
	}
	return result, nil
}

// First reads a single item matching the filter, or nil when there is none.
//
// A missing item is not an error - the caller usually wants a 404, which is a
// different thing from "the CMS is broken".
func (c *Client) First(ctx context.Context, model string, filter map[string]any, populate int) (Content, error) {
	res, err := c.Items(ctx, model, Query{Filter: filter, Limit: 1, Populate: populate})
	if err != nil {
		return nil, err
	}
	if len(res.Items) == 0 {
		return nil, nil
	}
	return res.Items[0], nil
}

// decodeItems normalises Cockpit's two response shapes into one Result.
//
// The wrapper must never be read as if it were the list: decoding
// {"data": [...], "meta": {...}} into a slice yields two entries with no _id,
// which silently defeats every id comparison downstream.
func decodeItems(body []byte) (Result, error) {
	trimmed := bytes.TrimLeft(body, " \t\r\n")

	if len(trimmed) == 0 {
		return Result{Items: []Content{}, Total: 0}, nil
	}

	if trimmed[0] == '[' {
		var items []Content
		if err := json.Unmarshal(trimmed, &items); err != nil {
			return Result{}, fmt.Errorf("decoding items: %w", err)
		}
		// No wrapper means no meta, so the only honest total is what arrived.
		return Result{Items: items, Total: len(items)}, nil
	}

	var wrapper struct {
		Data []Content `json:"data"`
		Meta struct {
			Total *int `json:"total"`
		} `json:"meta"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(trimmed, &wrapper); err != nil {
		return Result{}, fmt.Errorf("decoding items: %w", err)
	}
	if wrapper.Error != "" {
		return Result{}, fmt.Errorf("cockpit: %s", wrapper.Error)
	}

	result := Result{Items: wrapper.Data, Total: -1}
	if result.Items == nil {
		result.Items = []Content{}
	}
	if wrapper.Meta.Total != nil {
		result.Total = *wrapper.Meta.Total
	}
	return result, nil
}

// fetchRaw is fetch's sibling for responses that are not a single JSON object.
func (c *Client) fetchRaw(ctx context.Context, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("api-key", c.token)
	req.Header.Set("Accept", "application/json")

	res, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cockpit returned %s", res.Status)
	}

	var buf bytes.Buffer
	if _, err := buf.ReadFrom(res.Body); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
