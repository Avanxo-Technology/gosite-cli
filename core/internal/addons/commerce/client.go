// Package commerce is the Go half of the Commerce addon: a typed Medusa v2
// Store API client and, on top of it, the storefront (PLP, PDP, cart, checkout).
//
// The client is the only thing in a site that talks to Medusa (design D2): the
// browser never sees the publishable key and never calls the Store API. Every
// request carries the key in x-publishable-api-key.
package commerce

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// PublishableKeyHeader is the header Medusa's Store API authenticates with.
const PublishableKeyHeader = "x-publishable-api-key"

// DefaultBaseURL is the commerce service's address on the project network
// (design D2). The site container reaches it by container name, never by a
// public domain.
const DefaultBaseURL = "http://medusa:9000"

// Client is a typed Medusa Store API client. It is safe for concurrent use.
type Client struct {
	baseURL string
	// keyFn returns the publishable key on each request. The storefront's key
	// arrives on a shared volume after startup, so it is read per request
	// rather than captured once.
	keyFn func() string
	http  *http.Client
}

// NewClient returns a client for baseURL authenticating with a fixed key. Tests
// and one-shot callers use this; the storefront uses NewClientWithKeyFunc.
func NewClient(baseURL, key string, timeout time.Duration) *Client {
	return newClient(baseURL, func() string { return key }, timeout)
}

// NewClientWithKeyFunc returns a client whose key is read per request.
func NewClientWithKeyFunc(baseURL string, keyFn func() string, timeout time.Duration) *Client {
	return newClient(baseURL, keyFn, timeout)
}

func newClient(baseURL string, keyFn func() string, timeout time.Duration) *Client {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	if keyFn == nil {
		keyFn = func() string { return "" }
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		keyFn:   keyFn,
		http:    &http.Client{Timeout: timeout},
	}
}

// APIError is a non-2xx Store API response. It keeps the status and the body so
// a caller can tell "not found" from "Medusa is down", and log the latter.
type APIError struct {
	Method string
	Path   string
	Status int
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("medusa %s %s: status %d: %s", e.Method, e.Path, e.Status, strings.TrimSpace(e.Body))
}

// IsNotFound reports whether err is a 404 from the Store API.
func IsNotFound(err error) bool {
	var api *APIError
	return errors.As(err, &api) && api.Status == http.StatusNotFound
}

// do sends a JSON request and decodes the JSON response into out (when non-nil).
func (c *Client) do(ctx context.Context, method, path string, query url.Values, body, out any) error {
	endpoint := c.baseURL + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("commerce: encode %s %s: %w", method, path, err)
		}
		reader = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return fmt.Errorf("commerce: build %s %s: %w", method, path, err)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set(PublishableKeyHeader, c.keyFn())

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("commerce: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	payload, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("commerce: read %s %s: %w", method, path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &APIError{Method: method, Path: path, Status: resp.StatusCode, Body: string(payload)}
	}
	if out == nil || len(payload) == 0 {
		return nil
	}
	if err := json.Unmarshal(payload, out); err != nil {
		return fmt.Errorf("commerce: decode %s %s: %w", method, path, err)
	}
	return nil
}

// --- Regions ---------------------------------------------------------------

// Region is a Medusa region: the currency and countries a cart is priced in.
type Region struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	CurrencyCode string    `json:"currency_code"`
	Countries    []Country `json:"countries"`
}

type Country struct {
	ISO2 string `json:"iso_2"`
}

func (c *Client) ListRegions(ctx context.Context) ([]Region, error) {
	var out struct {
		Regions []Region `json:"regions"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/regions", nil, nil, &out); err != nil {
		return nil, err
	}
	return out.Regions, nil
}

// --- Products and categories ----------------------------------------------

// Amount is a monetary value as Medusa serializes it (a JSON number preserving
// decimals). The storefront formats it; never do arithmetic on a float here.
type Amount = json.Number

type Product struct {
	ID          string           `json:"id"`
	Title       string           `json:"title"`
	Handle      string           `json:"handle"`
	Description string           `json:"description"`
	Thumbnail   string           `json:"thumbnail"`
	Status      string           `json:"status"`
	Images      []ProductImage   `json:"images"`
	Options     []ProductOption  `json:"options"`
	Variants    []ProductVariant `json:"variants"`
	Categories  []Category       `json:"categories"`
}

type ProductImage struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

type ProductOption struct {
	ID     string               `json:"id"`
	Title  string               `json:"title"`
	Values []ProductOptionValue `json:"values"`
}

type ProductOptionValue struct {
	ID    string `json:"id"`
	Value string `json:"value"`
}

type ProductVariant struct {
	ID                string            `json:"id"`
	Title             string            `json:"title"`
	SKU               string            `json:"sku"`
	Options           map[string]string `json:"options"`
	CalculatedPrice   *CalculatedPrice  `json:"calculated_price"`
	InventoryQuantity *int              `json:"inventory_quantity"`
}

type CalculatedPrice struct {
	CalculatedAmount Amount `json:"calculated_amount"`
	CurrencyCode     string `json:"currency_code"`
}

type Category struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Handle   string `json:"handle"`
	ParentID string `json:"parent_category_id"`
}

// ProductListParams filters and paginates ListProducts. Zero values mean "no
// filter", except Limit, where 0 means the page default. RegionID makes Medusa
// return calculated prices in the region's currency.
type ProductListParams struct {
	Handle     string
	CategoryID string
	RegionID   string
	Limit      int
	Offset     int
}

// ProductList is one page of products plus the total count, so the PLP can
// render pagination without a second request.
type ProductList struct {
	Products []Product
	Count    int
	Offset   int
	Limit    int
}

func (c *Client) ListProducts(ctx context.Context, p ProductListParams) (*ProductList, error) {
	query := url.Values{}
	if p.Handle != "" {
		query.Set("handle", p.Handle)
	}
	if p.CategoryID != "" {
		query.Set("category_id", p.CategoryID)
	}
	if p.RegionID != "" {
		query.Set("region_id", p.RegionID)
	}
	// calculated_price needs the wildcard field selector and a region context;
	// inventory_quantity needs '+', or variants arrive with no price/stock.
	query.Set("fields", "+variants.inventory_quantity,*variants.calculated_price")
	if p.Limit > 0 {
		query.Set("limit", fmt.Sprintf("%d", p.Limit))
	}
	if p.Offset > 0 {
		query.Set("offset", fmt.Sprintf("%d", p.Offset))
	}

	var out struct {
		Products []Product `json:"products"`
		Count    int       `json:"count"`
		Offset   int       `json:"offset"`
		Limit    int       `json:"limit"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/products", query, nil, &out); err != nil {
		return nil, err
	}
	return &ProductList{Products: out.Products, Count: out.Count, Offset: out.Offset, Limit: out.Limit}, nil
}

// ProductByHandle returns the first product with that handle. A missing or
// unpublished product is a 404 and comes back as an *APIError with IsNotFound.
func (c *Client) ProductByHandle(ctx context.Context, handle string) (*Product, error) {
	list, err := c.ListProducts(ctx, ProductListParams{Handle: handle, Limit: 1})
	if err != nil {
		return nil, err
	}
	if len(list.Products) == 0 {
		return nil, &APIError{Method: http.MethodGet, Path: "/store/products", Status: http.StatusNotFound, Body: fmt.Sprintf("no product with handle %q", handle)}
	}
	return &list.Products[0], nil
}

func (c *Client) ListCategories(ctx context.Context) ([]Category, error) {
	var out struct {
		Categories []Category `json:"product_categories"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/product-categories", nil, nil, &out); err != nil {
		return nil, err
	}
	return out.Categories, nil
}

// --- Cart ------------------------------------------------------------------

type Cart struct {
	ID                string             `json:"id"`
	RegionID          string             `json:"region_id"`
	CurrencyCode      string             `json:"currency_code"`
	Email             string             `json:"email"`
	Items             []LineItem         `json:"items"`
	ShippingAddress   *Address           `json:"shipping_address"`
	BillingAddress    *Address           `json:"billing_address"`
	ShippingMethods   []ShippingMethod   `json:"shipping_methods"`
	PaymentCollection *PaymentCollection `json:"payment_collection"`
	Subtotal          Amount             `json:"subtotal"`
	ShippingTotal     Amount             `json:"shipping_total"`
	TaxTotal          Amount             `json:"tax_total"`
	Total             Amount             `json:"total"`
	ItemTotal         Amount             `json:"item_total"`
	CompletedAt       *string            `json:"completed_at"`
}

type Address struct {
	FirstName   string `json:"first_name"`
	LastName    string `json:"last_name"`
	Address1    string `json:"address_1"`
	Address2    string `json:"address_2"`
	City        string `json:"city"`
	PostalCode  string `json:"postal_code"`
	Province    string `json:"province"`
	CountryCode string `json:"country_code"`
	Phone       string `json:"phone"`
}

type LineItem struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	VariantID     string `json:"variant_id"`
	ProductID     string `json:"product_id"`
	ProductHandle string `json:"product_handle"`
	Thumbnail     string `json:"thumbnail"`
	Quantity      int    `json:"quantity"`
	UnitPrice     Amount `json:"unit_price"`
	Total         Amount `json:"total"`
}

type ShippingMethod struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Amount   Amount `json:"amount"`
	OptionID string `json:"shipping_option_id"`
}

type ShippingOption struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Amount    Amount `json:"amount"`
	PriceType string `json:"price_type"`
}

type PaymentProvider struct {
	ID string `json:"id"`
}

type PaymentCollection struct {
	ID              string           `json:"id"`
	PaymentSessions []PaymentSession `json:"payment_sessions"`
}

type PaymentSession struct {
	ID         string         `json:"id"`
	ProviderID string         `json:"provider_id"`
	Status     string         `json:"status"`
	Data       map[string]any `json:"data"`
}

func (c *Client) CreateCart(ctx context.Context, regionID string) (*Cart, error) {
	body := map[string]any{"region_id": regionID}
	var out struct {
		Cart *Cart `json:"cart"`
	}
	if err := c.do(ctx, http.MethodPost, "/store/carts", nil, body, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

func (c *Client) GetCart(ctx context.Context, cartID string) (*Cart, error) {
	var out struct {
		Cart *Cart `json:"cart"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/carts/"+url.PathEscape(cartID), nil, nil, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

// UpdateCart patches the cart, for the email and the addresses the checkout
// steps set. fields is the partial cart body Medusa expects.
func (c *Client) UpdateCart(ctx context.Context, cartID string, fields map[string]any) (*Cart, error) {
	var out struct {
		Cart *Cart `json:"cart"`
	}
	if err := c.do(ctx, http.MethodPost, "/store/carts/"+url.PathEscape(cartID), nil, fields, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

func (c *Client) AddLineItem(ctx context.Context, cartID, variantID string, quantity int) (*Cart, error) {
	body := map[string]any{"variant_id": variantID, "quantity": quantity}
	var out struct {
		Cart *Cart `json:"cart"`
	}
	if err := c.do(ctx, http.MethodPost, "/store/carts/"+url.PathEscape(cartID)+"/line-items", nil, body, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

func (c *Client) UpdateLineItem(ctx context.Context, cartID, lineID string, quantity int) (*Cart, error) {
	body := map[string]any{"quantity": quantity}
	var out struct {
		Cart *Cart `json:"cart"`
	}
	path := "/store/carts/" + url.PathEscape(cartID) + "/line-items/" + url.PathEscape(lineID)
	if err := c.do(ctx, http.MethodPost, path, nil, body, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

func (c *Client) RemoveLineItem(ctx context.Context, cartID, lineID string) (*Cart, error) {
	var out struct {
		Cart *Cart `json:"cart"`
	}
	path := "/store/carts/" + url.PathEscape(cartID) + "/line-items/" + url.PathEscape(lineID)
	if err := c.do(ctx, http.MethodDelete, path, nil, nil, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

// --- Shipping --------------------------------------------------------------

func (c *Client) ListShippingOptions(ctx context.Context, cartID string) ([]ShippingOption, error) {
	query := url.Values{"cart_id": {cartID}}
	var out struct {
		ShippingOptions []ShippingOption `json:"shipping_options"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/shipping-options", query, nil, &out); err != nil {
		return nil, err
	}
	return out.ShippingOptions, nil
}

func (c *Client) AddShippingMethod(ctx context.Context, cartID, optionID string) (*Cart, error) {
	body := map[string]any{"option_id": optionID}
	var out struct {
		Cart *Cart `json:"cart"`
	}
	path := "/store/carts/" + url.PathEscape(cartID) + "/shipping-methods"
	if err := c.do(ctx, http.MethodPost, path, nil, body, &out); err != nil {
		return nil, err
	}
	return out.Cart, nil
}

// --- Payment ---------------------------------------------------------------

func (c *Client) ListPaymentProviders(ctx context.Context, regionID string) ([]PaymentProvider, error) {
	query := url.Values{"region_id": {regionID}}
	var out struct {
		PaymentProviders []PaymentProvider `json:"payment_providers"`
	}
	if err := c.do(ctx, http.MethodGet, "/store/payment-providers", query, nil, &out); err != nil {
		return nil, err
	}
	return out.PaymentProviders, nil
}

// CreatePaymentCollection creates the collection a cart's payment sessions hang
// off. The payments change initializes a session on it; the manual provider
// needs the collection to exist before completion.
func (c *Client) CreatePaymentCollection(ctx context.Context, cartID string) (*PaymentCollection, error) {
	body := map[string]any{"cart_id": cartID}
	var out struct {
		PaymentCollection *PaymentCollection `json:"payment_collection"`
	}
	if err := c.do(ctx, http.MethodPost, "/store/payment-collections", nil, body, &out); err != nil {
		return nil, err
	}
	return out.PaymentCollection, nil
}

func (c *Client) InitializePaymentSession(ctx context.Context, collectionID, providerID string) (*PaymentCollection, error) {
	body := map[string]any{"provider_id": providerID}
	var out struct {
		PaymentCollection *PaymentCollection `json:"payment_collection"`
	}
	path := "/store/payment-collections/" + url.PathEscape(collectionID) + "/payment-sessions"
	if err := c.do(ctx, http.MethodPost, path, nil, body, &out); err != nil {
		return nil, err
	}
	return out.PaymentCollection, nil
}

// --- Complete --------------------------------------------------------------

// Order is the placed order. Only the fields the confirmation page shows.
type Order struct {
	ID           string `json:"id"`
	DisplayID    int    `json:"display_id"`
	Email        string `json:"email"`
	CurrencyCode string `json:"currency_code"`
	Total        Amount `json:"total"`
}

// CompleteResult is Medusa's answer to complete: either it placed an order, or
// it failed and returned the cart plus an error. Both are HTTP 200; the caller
// must look at Type, never at the status code (design D7).
type CompleteResult struct {
	Type  string         `json:"type"`
	Order *Order         `json:"order"`
	Cart  *Cart          `json:"cart"`
	Error *CompleteError `json:"error"`
}

type CompleteError struct {
	Message string `json:"message"`
	Type    string `json:"type"`
}

// IsOrder reports whether the cart completed into an order.
func (r *CompleteResult) IsOrder() bool { return r.Type == "order" && r.Order != nil }

func (c *Client) CompleteCart(ctx context.Context, cartID string) (*CompleteResult, error) {
	var out CompleteResult
	path := "/store/carts/" + url.PathEscape(cartID) + "/complete"
	if err := c.do(ctx, http.MethodPost, path, nil, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}
