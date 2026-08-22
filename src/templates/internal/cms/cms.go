// Package cms is the Cockpit CMS client. Everything the app knows about the
// CMS lives here, so the rest of the code never sees an HTTP call.
package cms

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"__MODULE__/internal/config"
	"golang.org/x/sync/singleflight"
)

type Client struct {
	baseURL string
	token   string
	http    *http.Client
	log     *slog.Logger

	// sf deduplicates concurrent fetches for the same singleton or collection,
	// so a cache stampede never turns into N parallel Cockpit requests.
	sf singleflight.Group
}

func New(cfg config.Config, log *slog.Logger) *Client {
	return &Client{
		baseURL: cfg.CockpitURL,
		token:   cfg.CockpitToken,
		// Always bound the CMS call: without a timeout a slow Cockpit would
		// hold every request open, cache or not.
		http: &http.Client{Timeout: 5 * time.Second},
		log:  log,
	}
}

// Content is one piece of CMS content, kept as a map so a template can read
// {{.Content.headline}} without a struct having to exist first. Define a
// struct in this package once the shape of a model settles down.
type Content map[string]any

// Singleton fetches a Cockpit singleton by name, e.g. Singleton(ctx, "home").
//
// Cockpit exposes singletons at /api/content/item/<name> and collections at
// /api/content/items/<name>, both authenticated with an api-key header. Create
// a "home" singleton in the Cockpit admin and its fields show up here.
//
// Until it exists the request fails, so the caller gets an empty Content and a
// logged warning rather than an error page: the site still renders with the
// fallbacks in the template.
func (c *Client) Singleton(ctx context.Context, name string) Content {
	v, err, _ := c.sf.Do("singleton:"+name, func() (any, error) {
		return c.fetch(ctx, "/api/content/item/"+name)
	})
	if err != nil {
		c.log.Warn("cockpit unavailable, using template fallbacks", "item", name, "err", err)
		return Content{}
	}
	return v.(Content)
}

func (c *Client) fetch(ctx context.Context, path string) (Content, error) {
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

	var content Content
	if err := json.NewDecoder(res.Body).Decode(&content); err != nil {
		return nil, err
	}
	return content, nil
}
