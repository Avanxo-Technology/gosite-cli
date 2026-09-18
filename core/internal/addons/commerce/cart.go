package commerce

import (
	"context"
	"errors"
	"html/template"
	"net/http"
	"strconv"
	"strings"

	"github.com/labstack/echo/v5"
)

// cartPath is the cart page. It is fixed for now; unlike the PLP/PDP/checkout
// paths it is not a gosite.yml key.
const cartPath = "/carrito"

const (
	cartCookieName   = "gosite_cart"
	cartCookieMaxAge = 30 * 24 * 60 * 60
)

// cartRef is what the cookie holds: the cart id and the region it belongs to,
// so a cookie from another region can be dropped.
type cartRef struct {
	ID     string
	Region string
}

func encodeCartRef(ref cartRef) string { return ref.ID + "." + ref.Region }

func decodeCartRef(raw string) (cartRef, bool) {
	id, region, ok := strings.Cut(raw, ".")
	if !ok || id == "" || region == "" {
		return cartRef{}, false
	}
	return cartRef{ID: id, Region: region}, true
}

// setCartCookie writes the httpOnly, SameSite=Lax cookie (secure outside dev).
func (s *Commerce) setCartCookie(c *echo.Context, ref cartRef) {
	c.SetCookie(&http.Cookie{
		Name:     cartCookieName,
		Value:    encodeCartRef(ref),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   !s.Config.IsDev(),
		MaxAge:   cartCookieMaxAge,
	})
}

func (s *Commerce) clearCartCookie(c *echo.Context) {
	c.SetCookie(&http.Cookie{
		Name:     cartCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   !s.Config.IsDev(),
		MaxAge:   -1,
	})
}

// cartRefOf reads the cookie. A missing cookie, a malformed one or one from
// another region is no cookie at all.
func (s *Commerce) cartRefOf(c *echo.Context) (cartRef, bool) {
	cookie, err := c.Cookie(cartCookieName)
	if err != nil || cookie.Value == "" {
		return cartRef{}, false
	}
	ref, ok := decodeCartRef(cookie.Value)
	if !ok || ref.Region != currentRegion() {
		return cartRef{}, false
	}
	return ref, true
}

// loadCart returns the visitor's cart, or nil when there is none. A cookie
// whose cart no longer exists or was already completed is cleared (spec: stale
// cookie).
func (s *Commerce) loadCart(ctx context.Context, c *echo.Context) (*Cart, error) {
	ref, ok := s.cartRefOf(c)
	if !ok {
		return nil, nil
	}
	cart, err := s.client.GetCart(ctx, ref.ID)
	if err != nil {
		if IsNotFound(err) {
			s.clearCartCookie(c)
			return nil, nil
		}
		return nil, err
	}
	if cart.CompletedAt != nil {
		s.clearCartCookie(c)
		return nil, nil
	}
	return cart, nil
}

// --------------------------------------------------------------- handlers

// Add adds a variant to the cart, creating the cart on the first add (never on
// a page view, so a crawler creates nothing).
func (s *Commerce) Add(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	regionID, err := s.region(ctx)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	variantID := strings.TrimSpace(c.FormValue("variant_id"))
	if variantID == "" {
		return echo.ErrBadRequest
	}
	quantity := parseQuantity(c.FormValue("quantity"))
	handle := c.FormValue("handle")

	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	if cart == nil {
		cart, err = s.client.CreateCart(ctx, regionID)
		if err != nil {
			return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
		}
	}

	updated, err := s.client.AddLineItem(ctx, cart.ID, variantID, quantity)
	if err != nil {
		if isStockError(err) {
			return s.renderBuyError(c, ctx, regionID, handle, "Not enough stock for that quantity.")
		}
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not add to the cart", err)
	}
	s.setCartCookie(c, cartRef{ID: updated.ID, Region: currentRegion()})

	if !isHtmx(c) {
		return s.redirectBack(c)
	}
	data, err := s.buyData(ctx, regionID, handle, variantID)
	if err != nil && err != errNotFound {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not add to the cart", err)
	}
	primary, err := renderFragment("commerce-buy.html", data)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the product", err)
	}
	return s.cartFragments(c, primary, updated)
}

// UpdateLine changes a line's quantity.
func (s *Commerce) UpdateLine(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	if cart == nil {
		return echo.ErrNotFound
	}

	lineID := c.FormValue("line_id")
	if lineID == "" {
		return echo.ErrBadRequest
	}
	updated, err := s.client.UpdateLineItem(ctx, cart.ID, lineID, parseQuantity(c.FormValue("quantity")))
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not update the cart", err)
	}
	s.setCartCookie(c, cartRef{ID: updated.ID, Region: currentRegion()})
	return s.cartMutation(c, updated)
}

// RemoveLine removes a line.
func (s *Commerce) RemoveLine(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	if cart == nil {
		return echo.ErrNotFound
	}

	lineID := c.FormValue("line_id")
	if lineID == "" {
		return echo.ErrBadRequest
	}
	updated, err := s.client.RemoveLineItem(ctx, cart.ID, lineID)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not update the cart", err)
	}
	return s.cartMutation(c, updated)
}

// CartPage renders the cart. It is never cached: it is per visitor.
func (s *Commerce) CartPage(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}

	view := buildCartView(cart)
	lines, err := renderFragment("commerce-cart-lines.html", view)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the cart", err)
	}

	data := map[string]any{
		"Title": "Cart",
		"Path":  cartPath,
		"View":  view,
		"Lines": template.HTML(lines), //nolint:gosec // our own fragment
		"IsDev": s.Config.IsDev(),
	}
	var buf strings.Builder
	if err := s.Renderer.Page(&buf, "commerce-cart", data); err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the cart", err)
	}
	return s.h.Reply(c).Page([]byte(buf.String()), false)
}

// cartMutation answers an update/remove: the lines fragment plus the mini-cart
// as an out-of-band swap. Without htmx it redirects to the cart page.
func (s *Commerce) cartMutation(c *echo.Context, cart *Cart) error {
	if !isHtmx(c) {
		return c.Redirect(http.StatusSeeOther, cartPath)
	}
	lines, err := renderFragment("commerce-cart-lines.html", buildCartView(cart))
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the cart", err)
	}
	return s.cartFragments(c, lines, cart)
}

// cartFragments writes the primary fragment followed by the mini-cart oob.
func (s *Commerce) cartFragments(c *echo.Context, primary []byte, cart *Cart) error {
	mini, err := renderFragment("commerce-minicart.html", buildMiniCart(cart))
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the cart", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, append(primary, mini...))
}

// buyData loads the price and stock of one variant of a product.
func (s *Commerce) buyData(ctx context.Context, regionID, handle, variantID string) (buyData, error) {
	if handle == "" {
		return buyData{}, errNotFound
	}
	list, err := s.client.ListProducts(ctx, ProductListParams{Handle: handle, RegionID: regionID, Limit: 1})
	if err != nil {
		return buyData{}, err
	}
	if len(list.Products) == 0 {
		return buyData{}, errNotFound
	}
	variant := pickVariant(list.Products[0], variantID)
	if variant == nil {
		return buyData{}, errNotFound
	}
	def, _ := regionDefForCurrent()
	data := buyData{
		Handle:    handle,
		VariantID: variant.ID,
		Title:     variant.Title,
		Price:     priceLabel(*variant, def.currency),
		Currency:  strings.ToUpper(def.currency),
	}
	if variant.InventoryQuantity != nil {
		data.Stock = *variant.InventoryQuantity
		data.InStock = data.Stock > 0
		data.StockKnown = true
	} else {
		data.InStock = true
	}
	return data, nil
}

// renderBuyError re-serves the island with a message, so an out-of-stock add
// leaves the cart unchanged and shows why.
func (s *Commerce) renderBuyError(c *echo.Context, ctx context.Context, regionID, handle, message string) error {
	data, err := s.buyData(ctx, regionID, handle, "")
	if err != nil {
		return s.h.Reply(c).Text(http.StatusConflict, message)
	}
	data.Error = message
	html, err := renderFragment("commerce-buy.html", data)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the product", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, html)
}

// --------------------------------------------------------------- helpers

func isHtmx(c *echo.Context) bool {
	return c.Request().Header.Get("HX-Request") == "true"
}

// redirectBack returns the visitor where they came from, or to the cart when the
// referer is missing or from another host (an open redirect would be worse than
// the fallback).
func (s *Commerce) redirectBack(c *echo.Context) error {
	referer := c.Request().Referer()
	if referer == "" || !sameHost(referer, c.Request().Host) {
		return c.Redirect(http.StatusSeeOther, cartPath)
	}
	return c.Redirect(http.StatusSeeOther, referer)
}

func sameHost(raw, host string) bool {
	trimmed := strings.TrimPrefix(strings.TrimPrefix(raw, "http://"), "https://")
	return strings.HasPrefix(trimmed, host+"/") || trimmed == host
}

func parseQuantity(raw string) int {
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n < 1 {
		return 1
	}
	return n
}

// isStockError reports whether an add failed because the quantity exceeds the
// stock, which Medusa answers with a 400 naming stock or inventory.
func isStockError(err error) bool {
	var api *APIError
	if !errors.As(err, &api) {
		return false
	}
	body := strings.ToLower(api.Body)
	return api.Status == http.StatusBadRequest &&
		(strings.Contains(body, "stock") || strings.Contains(body, "inventory"))
}

// --------------------------------------------------------------- view models

type cartLineView struct {
	ID        string
	Title     string
	Handle    string
	Thumbnail string
	Quantity  int
	UnitPrice string
	Total     string
}

type cartView struct {
	Empty         bool
	Lines         []cartLineView
	ItemTotal     string
	ShippingTotal string
	TaxTotal      string
	Total         string
	Count         int
}

type miniCartView struct {
	Count int
	Total string
	Empty bool
	URL   string
}

func buildCartView(cart *Cart) cartView {
	view := cartView{Empty: true}
	if cart == nil {
		return view
	}
	def, _ := regionDefForCurrent()
	view.Empty = len(cart.Items) == 0
	view.ItemTotal = cart.ItemTotal.String()
	view.ShippingTotal = cart.ShippingTotal.String()
	view.TaxTotal = cart.TaxTotal.String()
	view.Total = cart.Total.String()
	for _, item := range cart.Items {
		view.Count += item.Quantity
		view.Lines = append(view.Lines, cartLineView{
			ID:        item.ID,
			Title:     item.Title,
			Handle:    item.ProductHandle,
			Thumbnail: item.Thumbnail,
			Quantity:  item.Quantity,
			UnitPrice: item.UnitPrice.String() + " " + strings.ToUpper(def.currency),
			Total:     item.Total.String() + " " + strings.ToUpper(def.currency),
		})
	}
	return view
}

func buildMiniCart(cart *Cart) miniCartView {
	view := miniCartView{URL: cartPath, Empty: true}
	if cart == nil {
		return view
	}
	def, _ := regionDefForCurrent()
	for _, item := range cart.Items {
		view.Count += item.Quantity
	}
	view.Empty = view.Count == 0
	view.Total = cart.Total.String() + " " + strings.ToUpper(def.currency)
	return view
}
