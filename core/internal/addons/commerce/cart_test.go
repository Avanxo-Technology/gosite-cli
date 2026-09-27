package commerce

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/app"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// cartFake is a stateful Store API: it creates carts, adds lines and counts how
// many carts were created, which is how "a crawler creates no cart" is proven.
type cartFake struct {
	t       *testing.T
	server  *httptest.Server
	mu      sync.Mutex
	creates int
	seq     int
	carts   map[string]*fakeCart
	// completeFails makes complete answer with a cart (payment error) instead
	// of an order.
	completeFails bool
}

type fakeCart struct {
	ID       string
	Items    []fakeItem
	Email    string
	Address  map[string]any
	Shipping []string
	PayCol   *fakePayCol
}

type fakePayCol struct {
	ID       string
	Sessions []string
}

type fakeItem struct {
	ID      string
	Variant string
	Title   string
	Handle  string
	Qty     int
	Unit    int
}

func newCartFake(t *testing.T) *cartFake {
	t.Helper()
	f := &cartFake{t: t, carts: map[string]*fakeCart{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.server.Close)
	return f
}

func (f *cartFake) creations() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.creates
}

func (f *cartFake) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	path := r.URL.Path

	switch {
	case strings.HasSuffix(path, "/store/regions"):
		writeJSON(w, `{"regions":[{"id":"reg_1","currency_code":"cop","countries":[{"iso_2":"co"}]}]}`)
	case strings.HasSuffix(path, "/store/product-categories"):
		writeJSON(w, `{"product_categories":[{"id":"pcat_1","name":"Shirts","handle":"shirts"}]}`)
	case strings.HasSuffix(path, "/store/products"):
		products := []map[string]any{productJSON("prod_1", "Tee", "tee", "pcat_1", "59900", 5)}
		writeJSONValue(w, map[string]any{"products": products, "count": len(products), "offset": 0, "limit": 12})
	case strings.HasSuffix(path, "/store/shipping-options"):
		writeJSON(w, `{"shipping_options":[{"id":"so_1","name":"Standard","amount":0,"price_type":"flat"}]}`)
	case strings.HasSuffix(path, "/store/payment-providers"):
		writeJSON(w, `{"payment_providers":[{"id":"pp_system_default"},{"id":"pp_unknown"}]}`)
	case strings.HasSuffix(path, "/store/payment-collections") && r.Method == http.MethodPost:
		f.createPaymentCollection(w, r)
	case strings.Contains(path, "/store/payment-collections/") && strings.HasSuffix(path, "/payment-sessions"):
		f.createPaymentSession(w, r)
	case strings.HasSuffix(path, "/store/carts") && r.Method == http.MethodPost:
		f.createCart(w)
	case strings.HasSuffix(path, "/store/carts/"+pathID(path)+"/complete"):
		f.completeCart(w, r)
	case strings.Contains(path, "/store/carts/"):
		f.cartRoute(w, r)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func pathID(path string) string {
	rest := strings.TrimPrefix(path, "/store/carts/")
	return strings.Split(rest, "/")[0]
}

func (f *cartFake) createPaymentCollection(w http.ResponseWriter, r *http.Request) {
	body := struct {
		CartID string `json:"cart_id"`
	}{}
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.mu.Lock()
	cart := f.carts[body.CartID]
	if cart == nil {
		f.mu.Unlock()
		w.WriteHeader(http.StatusNotFound)
		return
	}
	cart.PayCol = &fakePayCol{ID: "paycol_1"}
	f.mu.Unlock()
	writeJSONValue(w, map[string]any{"payment_collection": payColJSON(cart.PayCol)})
}

func (f *cartFake) completeCart(w http.ResponseWriter, r *http.Request) {
	id := pathID(r.URL.Path)
	f.mu.Lock()
	cart := f.carts[id]
	fails := f.completeFails
	f.mu.Unlock()
	if cart == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if fails {
		writeJSONValue(w, map[string]any{
			"type": "cart", "cart": cartJSON(cart),
			"error": map[string]any{"message": "payment not authorized", "type": "payment_error"},
		})
		return
	}
	writeJSON(w, `{"type":"order","order":{"id":"order_1","display_id":1,"total":59900}}`)
}

func (f *cartFake) createPaymentSession(w http.ResponseWriter, r *http.Request) {
	body := struct {
		ProviderID string `json:"provider_id"`
	}{}
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.mu.Lock()
	var col *fakePayCol
	for _, cart := range f.carts {
		if cart.PayCol != nil && cart.PayCol.ID == "paycol_1" {
			col = cart.PayCol
			break
		}
	}
	if col != nil {
		col.Sessions = append(col.Sessions, body.ProviderID)
	}
	f.mu.Unlock()
	writeJSONValue(w, map[string]any{"payment_collection": payColJSON(col)})
}

func payColJSON(col *fakePayCol) any {
	if col == nil {
		return nil
	}
	sessions := []map[string]any{}
	for i, p := range col.Sessions {
		sessions = append(sessions, map[string]any{"id": fmt.Sprintf("payses_%d", i+1), "provider_id": p, "status": "pending"})
	}
	return map[string]any{"id": col.ID, "payment_sessions": sessions}
}

func (f *cartFake) createCart(w http.ResponseWriter) {
	f.mu.Lock()
	f.seq++
	f.creates++
	cart := &fakeCart{ID: fmt.Sprintf("cart_%d", f.seq)}
	f.carts[cart.ID] = cart
	f.mu.Unlock()
	writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
}

func (f *cartFake) cartRoute(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/store/carts/")
	parts := strings.Split(rest, "/")
	id := parts[0]

	f.mu.Lock()
	cart, ok := f.carts[id]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		writeJSON(w, `{"message":"cart not found"}`)
		return
	}

	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	case len(parts) == 1 && r.Method == http.MethodPost:
		body := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		if v, ok := body["email"].(string); ok {
			cart.Email = v
		}
		if v, ok := body["shipping_address"].(map[string]any); ok {
			cart.Address = v
		}
		f.mu.Unlock()
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	case len(parts) == 2 && parts[1] == "line-items" && r.Method == http.MethodPost:
		body := struct {
			VariantID string `json:"variant_id"`
			Quantity  int    `json:"quantity"`
		}{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.VariantID == "oos_variant" {
			w.WriteHeader(http.StatusBadRequest)
			writeJSON(w, `{"message":"Not enough stock for the requested quantity"}`)
			return
		}
		f.mu.Lock()
		cart.Items = append(cart.Items, fakeItem{
			ID: "li_1", Variant: body.VariantID, Title: "Tee", Handle: "tee", Qty: body.Quantity, Unit: 59900,
		})
		f.mu.Unlock()
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	case len(parts) == 2 && parts[1] == "shipping-methods" && r.Method == http.MethodPost:
		body := struct {
			OptionID string `json:"option_id"`
		}{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		cart.Shipping = append(cart.Shipping, body.OptionID)
		f.mu.Unlock()
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	case len(parts) == 3 && parts[1] == "line-items" && r.Method == http.MethodPost:
		body := struct {
			Quantity int `json:"quantity"`
		}{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		for i := range cart.Items {
			if cart.Items[i].ID == parts[2] {
				cart.Items[i].Qty = body.Quantity
			}
		}
		f.mu.Unlock()
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	case len(parts) == 3 && parts[1] == "line-items" && r.Method == http.MethodDelete:
		f.mu.Lock()
		kept := cart.Items[:0]
		for _, it := range cart.Items {
			if it.ID != parts[2] {
				kept = append(kept, it)
			}
		}
		cart.Items = kept
		f.mu.Unlock()
		writeJSONValue(w, map[string]any{"cart": cartJSON(cart)})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func cartJSON(cart *fakeCart) map[string]any {
	items := []map[string]any{}
	total := 0
	for _, it := range cart.Items {
		items = append(items, map[string]any{
			"id": it.ID, "title": it.Title, "variant_id": it.Variant,
			"product_handle": it.Handle, "quantity": it.Qty,
			"unit_price": it.Unit, "total": it.Unit * it.Qty,
		})
		total += it.Unit * it.Qty
	}
	return map[string]any{
		"id": cart.ID, "region_id": "reg_1", "currency_code": "cop",
		"email":              cart.Email,
		"items":              items,
		"shipping_address":   cart.Address,
		"shipping_methods":   shippingMethodsJSON(cart.Shipping),
		"payment_collection": payColJSON(cart.PayCol),
		"item_total":         total,
		"total":              total,
	}
}

func shippingMethodsJSON(options []string) []map[string]any {
	methods := []map[string]any{}
	for i, opt := range options {
		methods = append(methods, map[string]any{
			"id": fmt.Sprintf("sm_%d", i+1), "name": "Standard", "amount": 0, "shipping_option_id": opt,
		})
	}
	return methods
}

func writeJSON(w http.ResponseWriter, raw string) {
	_, _ = w.Write([]byte(raw))
}

func writeJSONValue(w http.ResponseWriter, v any) {
	_ = json.NewEncoder(w).Encode(v)
}

// newCartApp mounts the storefront against the stateful fake.
func newCartApp(t *testing.T, fake *cartFake) *echo.Echo {
	t.Helper()
	resetConfig()

	keyPath := filepath.Join(t.TempDir(), "publishable_key")
	if err := os.WriteFile(keyPath, []byte("pk_test"), 0o600); err != nil {
		t.Fatal(err)
	}
	key := NewPublishableKey(keyPath)
	key.Reload()
	client := NewClient(fake.server.URL, "pk_test", 15*time.Second)

	cfg := config.Config{RedisURL: testRedisURL(t), Environment: "production"}
	a, err := app.NewApp(cfg, testLogger(), views.WithPages(fs.FS(pages)))
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	a.Redis.FlushDB(t.Context())

	mount := func(e *echo.Echo, h *handlers.Handlers) { mount(e, h, client, key) }
	return app.NewRouter(a, app.RouterOptions{Mounts: []func(*echo.Echo, *handlers.Handlers){mount}})
}

func post(t *testing.T, e *echo.Echo, path, body string, hx bool, cookie *http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if hx {
		req.Header.Set("HX-Request", "true")
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	return rec
}

func responseCookie(t *testing.T, rec *httptest.ResponseRecorder, name string) *http.Cookie {
	t.Helper()
	// Later Set-Cookie wins, as in a browser: a stale cart is cleared and the
	// new one set in the same response.
	var found *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == name {
			found = c
		}
	}
	return found
}

func TestCrawlerCreatesNoCart(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	get(t, e, "/tienda")
	get(t, e, "/producto/tee")
	get(t, e, "/_commerce/buy/tee")

	if n := fake.creations(); n != 0 {
		t.Fatalf("page views created %d cart(s), want 0", n)
	}
}

func TestAddCreatesCartLazilyAndSetsCookie(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", true, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("add = %d: %s", rec.Code, rec.Body.String())
	}
	if n := fake.creations(); n != 1 {
		t.Fatalf("creations = %d, want 1", n)
	}
	cookie := responseCookie(t, rec, cartCookieName)
	if cookie == nil || !strings.HasPrefix(cookie.Value, "cart_1.co") {
		t.Fatalf("cart cookie = %+v", cookie)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `id="commerce-minicart"`) || !strings.Contains(body, "hx-swap-oob") {
		t.Fatalf("add response missing the oob mini-cart: %s", body)
	}
}

func TestAddOutOfStockLeavesCartUnchanged(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	rec := post(t, e, "/_commerce/add", "variant_id=oos_variant&handle=tee&quantity=99", true, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("out-of-stock add = %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Not enough stock") {
		t.Fatalf("missing the out-of-stock message: %s", rec.Body.String())
	}
	if c := responseCookie(t, rec, cartCookieName); c != nil {
		t.Fatalf("out-of-stock add set a cart cookie: %+v", c)
	}
}

func TestStaleCookieIsDroppedAndReplaced(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	stale := &http.Cookie{Name: cartCookieName, Value: "cart_missing.co"}
	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", true, stale)
	if rec.Code != http.StatusOK {
		t.Fatalf("add with stale cookie = %d", rec.Code)
	}
	cookie := responseCookie(t, rec, cartCookieName)
	if cookie == nil || cookie.Value == stale.Value {
		t.Fatalf("stale cookie was not replaced: %+v", cookie)
	}
}

func TestOtherRegionCookieIsIgnored(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	other := &http.Cookie{Name: cartCookieName, Value: "cart_1.us"}
	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", true, other)
	cookie := responseCookie(t, rec, cartCookieName)
	if cookie == nil || !strings.HasSuffix(cookie.Value, ".co") {
		t.Fatalf("cookie from another region was kept: %+v", cookie)
	}
}

func TestQuantityUpdateReturnsLinesAndMiniCart(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	added := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", true, nil)
	cookie := responseCookie(t, added, cartCookieName)
	if cookie == nil {
		t.Fatal("no cart cookie after add")
	}

	rec := post(t, e, "/_commerce/cart/update", "line_id=li_1&quantity=3", true, cookie)
	if rec.Code != http.StatusOK {
		t.Fatalf("update = %d: %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Tee") || !strings.Contains(body, `value="3"`) {
		t.Fatalf("update did not return the updated line: %s", body)
	}
	if !strings.Contains(body, `id="commerce-minicart"`) || !strings.Contains(body, "hx-swap-oob") {
		t.Fatalf("update did not return the oob mini-cart: %s", body)
	}
	if !strings.Contains(body, "3 items") {
		t.Fatalf("mini-cart count not updated: %s", body)
	}
}

func TestNoJavaScriptAddRedirectsBack(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	req := httptest.NewRequest(http.MethodPost, "/_commerce/add", strings.NewReader("variant_id=prod_1_v1&handle=tee&quantity=1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Referer", "http://example.com/producto/tee")
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("no-JS add = %d, want 303", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "http://example.com/producto/tee" {
		t.Fatalf("redirect = %q", loc)
	}
}

func TestCartPageRendersLines(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	empty := get(t, e, cartPath)
	if empty.Code != http.StatusOK || !strings.Contains(empty.Body.String(), "empty") {
		t.Fatalf("empty cart page = %d", empty.Code)
	}

	added := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=2", true, nil)
	cookie := responseCookie(t, added, cartCookieName)

	req := httptest.NewRequest(http.MethodGet, cartPath, nil)
	req.AddCookie(cookie)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Tee") {
		t.Fatalf("cart page = %d: %s", rec.Code, rec.Body.String())
	}
}
