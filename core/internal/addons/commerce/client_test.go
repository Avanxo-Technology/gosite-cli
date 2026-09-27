package commerce

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeStore is an httptest server that records what the client sent and answers
// with a canned status/body. It asserts the publishable key on every request,
// because a Store API call without it is the bug this client exists to prevent.
type fakeStore struct {
	t      *testing.T
	server *httptest.Server
	key    string

	lastMethod string
	lastPath   string
	lastQuery  map[string]string
	lastBody   map[string]any
}

func newFakeStore(t *testing.T, status int, body string) *fakeStore {
	t.Helper()
	f := &fakeStore{t: t, key: "pk_test_123"}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get(PublishableKeyHeader); got != f.key {
			t.Errorf("%s %s: %s = %q, want %q", r.Method, r.URL.Path, PublishableKeyHeader, got, f.key)
		}
		f.lastMethod = r.Method
		f.lastPath = r.URL.Path
		f.lastQuery = map[string]string{}
		for k, v := range r.URL.Query() {
			if len(v) > 0 {
				f.lastQuery[k] = v[0]
			}
		}
		f.lastBody = map[string]any{}
		if r.Body != nil {
			_ = json.NewDecoder(r.Body).Decode(&f.lastBody)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeStore) client() *Client {
	return NewClient(f.server.URL, f.key, 2*time.Second)
}

func TestListProductsSendsFiltersAndPagination(t *testing.T) {
	f := newFakeStore(t, http.StatusOK, `{
		"products":[{"id":"prod_1","title":"Tee","handle":"tee","variants":[{"id":"var_1","calculated_price":{"calculated_amount":19.99,"currency_code":"usd"}}]}],
		"count":41,"offset":20,"limit":20
	}`)

	list, err := f.client().ListProducts(context.Background(), ProductListParams{
		CategoryID: "pcat_1", Limit: 20, Offset: 20,
	})
	if err != nil {
		t.Fatal(err)
	}
	if f.lastMethod != http.MethodGet || f.lastPath != "/store/products" {
		t.Fatalf("request = %s %s", f.lastMethod, f.lastPath)
	}
	if f.lastQuery["category_id"] != "pcat_1" || f.lastQuery["limit"] != "20" || f.lastQuery["offset"] != "20" {
		t.Fatalf("query = %v", f.lastQuery)
	}
	if list.Count != 41 || list.Limit != 20 || len(list.Products) != 1 {
		t.Fatalf("list = %+v", list)
	}
	if got := list.Products[0].Variants[0].CalculatedPrice.CalculatedAmount.String(); got != "19.99" {
		t.Fatalf("amount = %q, want 19.99", got)
	}
}

func TestProductByHandleNotFound(t *testing.T) {
	f := newFakeStore(t, http.StatusOK, `{"products":[],"count":0}`)

	_, err := f.client().ProductByHandle(context.Background(), "nope")
	if err == nil || !IsNotFound(err) {
		t.Fatalf("err = %v, want a not-found error", err)
	}
}

func TestProductByHandleFound(t *testing.T) {
	f := newFakeStore(t, http.StatusOK, `{"products":[{"id":"prod_1","handle":"tee"}],"count":1}`)

	p, err := f.client().ProductByHandle(context.Background(), "tee")
	if err != nil {
		t.Fatal(err)
	}
	if p.ID != "prod_1" || f.lastQuery["handle"] != "tee" || f.lastQuery["limit"] != "1" {
		t.Fatalf("product = %+v query = %v", p, f.lastQuery)
	}
}

func TestCreateCartPostsRegion(t *testing.T) {
	f := newFakeStore(t, http.StatusOK, `{"cart":{"id":"cart_1","region_id":"reg_1","currency_code":"usd"}}`)

	cart, err := f.client().CreateCart(context.Background(), "reg_1")
	if err != nil {
		t.Fatal(err)
	}
	if f.lastMethod != http.MethodPost || f.lastPath != "/store/carts" {
		t.Fatalf("request = %s %s", f.lastMethod, f.lastPath)
	}
	if f.lastBody["region_id"] != "reg_1" {
		t.Fatalf("body = %v", f.lastBody)
	}
	if cart.ID != "cart_1" {
		t.Fatalf("cart = %+v", cart)
	}
}

func TestLineItemPathsAndMethods(t *testing.T) {
	ok := `{"cart":{"id":"cart_1","items":[]}}`

	t.Run("add", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, ok)
		if _, err := f.client().AddLineItem(context.Background(), "cart_1", "var_1", 2); err != nil {
			t.Fatal(err)
		}
		if f.lastPath != "/store/carts/cart_1/line-items" || f.lastBody["variant_id"] != "var_1" || f.lastBody["quantity"].(float64) != 2 {
			t.Fatalf("%s %v", f.lastPath, f.lastBody)
		}
	})

	t.Run("update", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, ok)
		if _, err := f.client().UpdateLineItem(context.Background(), "cart_1", "li_1", 3); err != nil {
			t.Fatal(err)
		}
		if f.lastMethod != http.MethodPost || f.lastPath != "/store/carts/cart_1/line-items/li_1" || f.lastBody["quantity"].(float64) != 3 {
			t.Fatalf("%s %s %v", f.lastMethod, f.lastPath, f.lastBody)
		}
	})

	t.Run("remove", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, ok)
		if _, err := f.client().RemoveLineItem(context.Background(), "cart_1", "li_1"); err != nil {
			t.Fatal(err)
		}
		if f.lastMethod != http.MethodDelete || f.lastPath != "/store/carts/cart_1/line-items/li_1" {
			t.Fatalf("%s %s", f.lastMethod, f.lastPath)
		}
	})
}

func TestShippingAndPayment(t *testing.T) {
	t.Run("list shipping options for the cart", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"shipping_options":[{"id":"so_1","name":"Standard","price_type":"flat"}]}`)
		opts, err := f.client().ListShippingOptions(context.Background(), "cart_1")
		if err != nil {
			t.Fatal(err)
		}
		if f.lastQuery["cart_id"] != "cart_1" || len(opts) != 1 || opts[0].ID != "so_1" {
			t.Fatalf("query=%v opts=%+v", f.lastQuery, opts)
		}
	})

	t.Run("add shipping method", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"cart":{"id":"cart_1"}}`)
		if _, err := f.client().AddShippingMethod(context.Background(), "cart_1", "so_1"); err != nil {
			t.Fatal(err)
		}
		if f.lastPath != "/store/carts/cart_1/shipping-methods" || f.lastBody["option_id"] != "so_1" {
			t.Fatalf("%s %v", f.lastPath, f.lastBody)
		}
	})

	t.Run("list providers for the region", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"payment_providers":[{"id":"pp_system_default"}]}`)
		providers, err := f.client().ListPaymentProviders(context.Background(), "reg_1")
		if err != nil {
			t.Fatal(err)
		}
		if f.lastQuery["region_id"] != "reg_1" || len(providers) != 1 {
			t.Fatalf("query=%v providers=%+v", f.lastQuery, providers)
		}
	})

	t.Run("create collection and initialize session", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"payment_collection":{"id":"paycol_1","payment_sessions":[{"id":"payses_1","provider_id":"pp_system_default","status":"pending"}]}}`)
		collection, err := f.client().CreatePaymentCollection(context.Background(), "cart_1")
		if err != nil {
			t.Fatal(err)
		}
		if f.lastPath != "/store/payment-collections" || f.lastBody["cart_id"] != "cart_1" {
			t.Fatalf("%s %v", f.lastPath, f.lastBody)
		}
		if _, err := f.client().InitializePaymentSession(context.Background(), collection.ID, "pp_system_default"); err != nil {
			t.Fatal(err)
		}
		if f.lastPath != "/store/payment-collections/paycol_1/payment-sessions" || f.lastBody["provider_id"] != "pp_system_default" {
			t.Fatalf("%s %v", f.lastPath, f.lastBody)
		}
	})
}

// The bug this guards: complete answers HTTP 200 whether it placed an order or
// failed, so the caller must switch on `type` and never on the status code.
func TestCompleteCartDistinguishesOrderFromFailure(t *testing.T) {
	t.Run("order", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"type":"order","order":{"id":"order_1","display_id":1024,"total":19.99}}`)
		result, err := f.client().CompleteCart(context.Background(), "cart_1")
		if err != nil {
			t.Fatal(err)
		}
		if !result.IsOrder() || result.Order.DisplayID != 1024 {
			t.Fatalf("result = %+v", result)
		}
		if f.lastPath != "/store/carts/cart_1/complete" {
			t.Fatalf("path = %s", f.lastPath)
		}
	})

	t.Run("cart with error", func(t *testing.T) {
		f := newFakeStore(t, http.StatusOK, `{"type":"cart","cart":{"id":"cart_1"},"error":{"message":"payment not authorized","type":"payment_error"}}`)
		result, err := f.client().CompleteCart(context.Background(), "cart_1")
		if err != nil {
			t.Fatal(err)
		}
		if result.IsOrder() {
			t.Fatalf("result = %+v, want not an order", result)
		}
		if result.Error == nil || result.Error.Message != "payment not authorized" {
			t.Fatalf("error = %+v", result.Error)
		}
	})
}

func TestAPIErrorKeepsStatusAndBody(t *testing.T) {
	f := newFakeStore(t, http.StatusInternalServerError, `{"message":"boom"}`)

	_, err := f.client().CreateCart(context.Background(), "reg_1")
	if err == nil {
		t.Fatal("expected an error")
	}
	if IsNotFound(err) {
		t.Fatal("a 500 is not a 404")
	}
	if !strings.Contains(err.Error(), "500") || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("err = %v, want status and body", err)
	}
}
