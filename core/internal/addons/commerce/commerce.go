package commerce

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
)

// productsPerPage is how many products the PLP lists.
const productsPerPage = 12

// commerceTimeout bounds a Store API call made while rendering.
const commerceTimeout = 10 * time.Second

// buyPath is the island route. The PDP embeds it with htmx, so it is served
// live (never cached) while the page around it is cached.
const buyPath = "/_commerce/buy/:handle"

// errNotFound distinguishes "this product does not exist" from "Medusa is
// broken". Only the second is worth a 502.
var errNotFound = fmt.Errorf("not found")

// Commerce is the mounted storefront: the Medusa client plus the routes it
// serves.
type Commerce struct {
	handlers.Deps
	h *handlers.Handlers

	client *Client
	key    *PublishableKey

	mu       sync.RWMutex
	regionID string
}

// Mount registers the storefront routes. It is the addon's Go half.
func Mount(e *echo.Echo, h *handlers.Handlers) *Commerce {
	return mount(e, h, nil, nil)
}

// mount is Mount with injectable dependencies, which is what tests use.
func mount(e *echo.Echo, h *handlers.Handlers, client *Client, key *PublishableKey) *Commerce {
	s := &Commerce{Deps: h.Deps, h: h}

	s.key = key
	if s.key == nil {
		s.key = NewPublishableKey(os.Getenv("COMMERCE_KEY_FILE"))
	}
	if client != nil {
		s.client = client
	} else {
		s.client = NewClientWithKeyFunc(BaseURL(), func() string {
			v, _ := s.key.Get()
			return v
		}, commerceTimeout)
		// In production the key arrives on the shared volume after the seed
		// writes it; wait for it in the background so the rest of the site
		// keeps serving and only the store routes answer 503 meanwhile.
		go s.refresh(context.Background())
	}

	e.GET(cfgPLPPath, s.PLP)
	e.GET(strings.TrimRight(cfgPDPPath, "/")+"/:handle", s.PDP)
	e.GET(buyPath, s.Buy)
	e.GET(cartPath, s.CartPage)
	e.POST("/_commerce/add", s.Add)
	e.POST("/_commerce/cart/update", s.UpdateLine)
	e.POST("/_commerce/cart/remove", s.RemoveLine)

	checkout := strings.TrimRight(cfgCheckoutPath, "/")
	e.GET(cfgCheckoutPath, s.Checkout)
	e.GET(checkout+"/gracias/:id", s.Confirmation)
	e.POST("/_commerce/checkout/email", s.CheckoutEmail)
	e.POST("/_commerce/checkout/address", s.CheckoutAddress)
	e.POST("/_commerce/checkout/shipping", s.CheckoutShipping)
	e.POST("/_commerce/checkout/payment", s.CheckoutPayment)
	e.POST("/_commerce/checkout/complete", s.CheckoutComplete)
	e.GET(checkout+"/retorno", s.ReturnRoute)

	return s
}

// refresh waits for the publishable key and resolves the region. Both are
// retried per request until they succeed, so a slow Medusa never breaks boot.
func (s *Commerce) refresh(ctx context.Context) {
	s.key.Wait(ctx, 2*time.Second, s.Log)
	if _, err := s.resolveRegionID(ctx); err != nil {
		s.Log.Warn("commerce: could not resolve the store region yet", "err", err)
	}
}

// ready reports whether the store can be served. Store routes answer 503 until
// the seed has written the key (design D2).
func (s *Commerce) ready(c *echo.Context) bool {
	if _, ok := s.key.Get(); !ok {
		_ = s.h.Reply(c).Text(http.StatusServiceUnavailable, "the store is starting up")
		return false
	}
	return true
}

// region returns the Medusa region id for the configured commerce_region,
// resolving it once and caching it.
func (s *Commerce) region(ctx context.Context) (string, error) {
	s.mu.RLock()
	id := s.regionID
	s.mu.RUnlock()
	if id != "" {
		return id, nil
	}
	return s.resolveRegionID(ctx)
}

func (s *Commerce) resolveRegionID(ctx context.Context) (string, error) {
	def, ok := regionDefForCurrent()
	if !ok {
		return "", fmt.Errorf("commerce: unknown region %q", currentRegion())
	}
	regions, err := s.client.ListRegions(ctx)
	if err != nil {
		return "", err
	}
	for _, r := range regions {
		if r.CurrencyCode == def.currency {
			s.setRegionID(r.ID)
			return r.ID, nil
		}
		for _, c := range r.Countries {
			if c.ISO2 == def.country {
				s.setRegionID(r.ID)
				return r.ID, nil
			}
		}
	}
	return "", fmt.Errorf("commerce: Medusa has no region for %q; has the seed run?", currentRegion())
}

func (s *Commerce) setRegionID(id string) {
	s.mu.Lock()
	s.regionID = id
	s.mu.Unlock()
}

// cacheKey namespaces commerce pages under the region, so the existing purge
// reaches them and a region change cannot serve another region's prices. The
// key is built only from what the page depends on, never from the raw URL:
// otherwise every "?x=N" a client invents would render, call Medusa and store
// a new entry. Unknown categories, handles and pages are 404s, never cached,
// so the set of keys is bounded by the catalogue.
func (s *Commerce) cacheKey(parts ...string) string {
	return s.Config.CacheKeyPrefix() + "page:commerce:" + currentRegion() + ":" + strings.Join(parts, ":")
}

// PLP serves the product listing, cached per region, category and page.
func (s *Commerce) PLP(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	regionID, err := s.region(ctx)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	page := 1
	if raw := c.QueryParam("page"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			return echo.ErrNotFound
		}
		page = parsed
	}
	category := c.QueryParam("category")

	html, cached, err := s.h.Cache.HTML(ctx, s.cacheKey("plp", category, strconv.Itoa(page)), func() ([]byte, error) {
		return s.renderPLP(ctx, regionID, category, page)
	})
	if err != nil {
		if err == errNotFound {
			return echo.ErrNotFound
		}
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	return s.h.Reply(c).Page(html, cached)
}

// PDP serves one product, cached per region and handle.
func (s *Commerce) PDP(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	regionID, err := s.region(ctx)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	handle := c.Param("handle")
	html, cached, err := s.h.Cache.HTML(ctx, s.cacheKey("pdp", handle), func() ([]byte, error) {
		return s.renderPDP(ctx, regionID, handle)
	})
	if err != nil {
		if err == errNotFound {
			return echo.ErrNotFound
		}
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	return s.h.Reply(c).Page(html, cached)
}

// Buy is the PDP island: price, stock and the add form for one variant, served
// live and never cached.
func (s *Commerce) Buy(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	regionID, err := s.region(ctx)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	handle := c.Param("handle")
	data, err := s.buyData(ctx, regionID, handle, c.QueryParam("v"))
	if err != nil {
		if err == errNotFound {
			return echo.ErrNotFound
		}
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	html, err := renderFragment("commerce-buy.html", data)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the product", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, html)
}

// --------------------------------------------------------------- renders

func (s *Commerce) renderPLP(ctx context.Context, regionID, categoryHandle string, page int) ([]byte, error) {
	categories, err := s.client.ListCategories(ctx)
	if err != nil {
		return nil, err
	}
	categoryID := ""
	if categoryHandle != "" {
		for _, cat := range categories {
			if cat.Handle == categoryHandle {
				categoryID = cat.ID
				break
			}
		}
		if categoryID == "" {
			return nil, errNotFound
		}
	}

	list, err := s.client.ListProducts(ctx, ProductListParams{
		CategoryID: categoryID,
		RegionID:   regionID,
		Limit:      productsPerPage,
		Offset:     (page - 1) * productsPerPage,
	})
	if err != nil {
		return nil, err
	}
	if len(list.Products) == 0 && page > 1 {
		return nil, errNotFound
	}

	def, _ := regionDefForCurrent()
	views := make([]productView, 0, len(list.Products))
	for _, p := range list.Products {
		views = append(views, buildProductView(p, def.currency))
	}

	data := map[string]any{
		"Title":      def.name,
		"Path":       cfgPLPPath,
		"Products":   views,
		"Categories": buildCategoryViews(categories, categoryHandle),
		"Currency":   strings.ToUpper(def.currency),
		"Page":       page,
		"HasMore":    list.Offset+len(list.Products) < list.Count,
		"PrevURL":    pageURL(cfgPLPPath, categoryHandle, page-1),
		"NextURL":    pageURL(cfgPLPPath, categoryHandle, page+1),
		"IsDev":      s.Config.IsDev(),
	}

	var buf bytes.Buffer
	if err := s.Renderer.Page(&buf, "commerce-plp", data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func (s *Commerce) renderPDP(ctx context.Context, regionID, handle string) ([]byte, error) {
	list, err := s.client.ListProducts(ctx, ProductListParams{Handle: handle, RegionID: regionID, Limit: 1})
	if err != nil {
		return nil, err
	}
	if len(list.Products) == 0 {
		return nil, errNotFound
	}
	product := list.Products[0]
	def, _ := regionDefForCurrent()
	view := buildProductView(product, def.currency)

	data := map[string]any{
		"Title":    product.Title,
		"Path":     strings.TrimRight(cfgPDPPath, "/") + "/" + product.Handle,
		"Product":  product,
		"View":     view,
		"Currency": strings.ToUpper(def.currency),
		"IsDev":    s.Config.IsDev(),
	}

	var buf bytes.Buffer
	if err := s.Renderer.Page(&buf, "commerce-pdp", data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// --------------------------------------------------------------- view models

type productView struct {
	Title     string
	Handle    string
	Thumbnail string
	URL       string
	Price     string
	Variants  []variantView
}

type variantView struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Price string `json:"price"`
}

type categoryView struct {
	Name     string
	URL      string
	Selected bool
}

func buildProductView(p Product, currency string) productView {
	view := productView{
		Title:     p.Title,
		Handle:    p.Handle,
		Thumbnail: p.Thumbnail,
		URL:       strings.TrimRight(cfgPDPPath, "/") + "/" + p.Handle,
	}
	for _, v := range p.Variants {
		view.Variants = append(view.Variants, variantView{
			ID:    v.ID,
			Title: v.Title,
			Price: priceLabel(v, currency),
		})
	}
	if len(p.Variants) > 0 {
		view.Price = priceLabel(p.Variants[0], currency)
	}
	return view
}

func buildCategoryViews(categories []Category, selected string) []categoryView {
	views := []categoryView{{Name: "All", URL: cfgPLPPath, Selected: selected == ""}}
	for _, cat := range categories {
		views = append(views, categoryView{
			Name:     cat.Name,
			URL:      cfgPLPPath + "?category=" + url.QueryEscape(cat.Handle),
			Selected: cat.Handle == selected,
		})
	}
	return views
}

// pickVariant returns the variant named by id, or the first one.
func pickVariant(p Product, id string) *ProductVariant {
	if len(p.Variants) == 0 {
		return nil
	}
	if id != "" {
		for i := range p.Variants {
			if p.Variants[i].ID == id {
				return &p.Variants[i]
			}
		}
	}
	return &p.Variants[0]
}

// priceLabel formats a variant's calculated price. Medusa stores amounts as
// decimals in the currency's major unit, so no scaling happens here.
func priceLabel(v ProductVariant, currency string) string {
	if v.CalculatedPrice == nil || v.CalculatedPrice.CalculatedAmount == "" {
		return ""
	}
	return v.CalculatedPrice.CalculatedAmount.String() + " " + strings.ToUpper(currency)
}

// pageURL builds a PLP link, or "" out of range so the template omits it.
func pageURL(path, category string, page int) string {
	if page < 1 {
		return ""
	}
	query := url.Values{}
	if category != "" {
		query.Set("category", category)
	}
	if page > 1 {
		query.Set("page", strconv.Itoa(page))
	}
	if len(query) == 0 {
		return path
	}
	return path + "?" + query.Encode()
}
