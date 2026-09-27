package commerce

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"github.com/labstack/echo/v5"
)

// templateHTML marks an already-rendered fragment as safe to embed.
func templateHTML(b []byte) template.HTML { return template.HTML(b) } //nolint:gosec // our own fragment

// Checkout steps. The step is never stored: it is derived from the cart, so a
// reload resumes where the visitor was (design D7).
const (
	stepEmail    = "email"
	stepAddress  = "address"
	stepShipping = "shipping"
	stepPayment  = "payment"
)

// confirmationCookie authorises the thanks page. It holds the order's display
// id signed with a per-process key, so guessing a number shows nothing.
const confirmationCookie = "gosite_order"

var (
	confirmationKey     = mustRandomKey()
	loggedUnknownMu     sync.Mutex
	loggedUnknownRender = map[string]bool{}
)

func mustRandomKey() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic("commerce: cannot generate a confirmation key: " + err.Error())
	}
	return key
}

// checkoutStep derives the step from the cart, in order.
func checkoutStep(cart *Cart) string {
	if cart.Email == "" {
		return stepEmail
	}
	if cart.ShippingAddress == nil {
		return stepAddress
	}
	if len(cart.ShippingMethods) == 0 {
		return stepShipping
	}
	return stepPayment
}

// Checkout renders the checkout page at the step the cart is on.
func (s *Commerce) Checkout(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	// No cart or an empty one has nothing to check out.
	if cart == nil || len(cart.Items) == 0 {
		return c.Redirect(http.StatusSeeOther, cfgPLPPath)
	}

	step := checkoutStep(cart)
	stepHTML, err := s.renderStep(ctx, cart, step, "")
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the checkout", err)
	}

	data := map[string]any{
		"Title": "Checkout",
		"Path":  cfgCheckoutPath,
		"Step":  step,
		"Body":  templateHTML(stepHTML),
		"IsDev": s.Config.IsDev(),
	}
	var buf strings.Builder
	if err := s.Renderer.Page(&buf, "commerce-checkout", data); err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the checkout", err)
	}
	return s.h.Reply(c).Page([]byte(buf.String()), false)
}

// CheckoutEmail sets the cart's email and advances to the address step.
func (s *Commerce) CheckoutEmail(c *echo.Context) error {
	return s.step(c, func(ctx context.Context, cart *Cart) (*Cart, error) {
		email := strings.TrimSpace(c.FormValue("email"))
		if email == "" {
			return cart, errInvalidStep
		}
		return s.client.UpdateCart(ctx, cart.ID, CartUpdate{Email: email})
	})
}

// CheckoutAddress sets the shipping (and billing) address and advances to
// shipping. The form fields are the same whatever the region; the region only
// changes the labels the fragment shows.
func (s *Commerce) CheckoutAddress(c *echo.Context) error {
	return s.step(c, func(ctx context.Context, cart *Cart) (*Cart, error) {
		def, _ := regionDefForCurrent()
		address := &Address{
			FirstName:   strings.TrimSpace(c.FormValue("first_name")),
			LastName:    strings.TrimSpace(c.FormValue("last_name")),
			Address1:    strings.TrimSpace(c.FormValue("address_1")),
			Address2:    strings.TrimSpace(c.FormValue("address_2")),
			City:        strings.TrimSpace(c.FormValue("city")),
			Province:    strings.TrimSpace(c.FormValue("province")),
			PostalCode:  strings.TrimSpace(c.FormValue("postal_code")),
			Phone:       strings.TrimSpace(c.FormValue("phone")),
			CountryCode: def.country, // the region's country, never the form's
		}
		if address.Address1 == "" {
			return cart, errInvalidStep
		}
		return s.client.UpdateCart(ctx, cart.ID, CartUpdate{ShippingAddress: address, BillingAddress: address})
	})
}

// CheckoutShipping sets the shipping method and advances to payment.
func (s *Commerce) CheckoutShipping(c *echo.Context) error {
	return s.step(c, func(ctx context.Context, cart *Cart) (*Cart, error) {
		optionID := c.FormValue("option_id")
		if optionID == "" {
			return cart, errInvalidStep
		}
		return s.client.AddShippingMethod(ctx, cart.ID, optionID)
	})
}

// CheckoutComplete ensures a payment session for the manual provider and
// completes the cart. An order clears the cookie and redirects to the thanks
// page; a failure keeps the cookie and shows the error on the payment step.
func (s *Commerce) CheckoutComplete(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	// A cart that is gone or already completed is a double submit: success.
	if cart == nil {
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}

	if _, err := s.ensureManualPayment(ctx, cart); err != nil {
		return s.completeFailed(c, ctx, cart, "Could not start the payment.")
	}

	result, err := s.client.CompleteCart(ctx, cart.ID)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not complete the order", err)
	}
	if result.IsOrder() {
		s.clearCartCookie(c)
		s.setConfirmationCookie(c, result.Order.DisplayID)
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath+"/gracias/"+strconv.Itoa(result.Order.DisplayID))
	}
	return s.completeFailed(c, ctx, cart, completeErrorMessage(result))
}

// Confirmation shows the thanks page, only for the browser that completed.
func (s *Commerce) Confirmation(c *echo.Context) error {
	if !s.ready(c) {
		return nil
	}
	displayID, err := strconv.Atoi(c.Param("id"))
	if err != nil || !s.confirmationValid(c, displayID) {
		return echo.ErrNotFound
	}
	data := map[string]any{
		"Title":     "Order placed",
		"Path":      cfgCheckoutPath,
		"DisplayID": displayID,
		"IsDev":     s.Config.IsDev(),
	}
	var buf strings.Builder
	if err := s.Renderer.Page(&buf, "commerce-confirmation", data); err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the confirmation", err)
	}
	return s.h.Reply(c).Page([]byte(buf.String()), false)
}

// --------------------------------------------------------------- step machine

// errInvalidStep means the submitted form was incomplete; the step is re-shown.
var errInvalidStep = errInvalidStepError{}

type errInvalidStepError struct{}

func (errInvalidStepError) Error() string { return "invalid step submission" }

// step runs a step's cart update and answers with the next step's fragment (or
// the whole checkout page without htmx).
func (s *Commerce) step(c *echo.Context, update func(context.Context, *Cart) (*Cart, error)) error {
	if !s.ready(c) {
		return nil
	}
	ctx := c.Request().Context()
	cart, err := s.loadCart(ctx, c)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the store", err)
	}
	if cart == nil {
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}

	updated, err := update(ctx, cart)
	if err != nil && err != errInvalidStep {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not update the checkout", err)
	}
	if err == errInvalidStep {
		updated = cart
	}
	s.setCartCookie(c, cartRef{ID: updated.ID, Region: currentRegion()})

	step := checkoutStep(updated)
	if !isHtmx(c) {
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}
	html, err := s.renderStep(ctx, updated, step, "")
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the checkout", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, html)
}

// completeFailed keeps the cart and re-renders the payment step with the error.
func (s *Commerce) completeFailed(c *echo.Context, ctx context.Context, cart *Cart, message string) error {
	if !isHtmx(c) {
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}
	html, err := s.renderStep(ctx, cart, stepPayment, message)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the checkout", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, html)
}

// renderStep renders the fragment for one step, optionally with an error.
func (s *Commerce) renderStep(ctx context.Context, cart *Cart, step, message string) ([]byte, error) {
	def, _ := regionDefForCurrent()
	data := map[string]any{
		"Cart":         cart,
		"View":         buildCartView(cart),
		"Region":       def,
		"CheckoutPath": cfgCheckoutPath,
		"Step":         step,
		"Error":        message,
		"Address":      cartAddress(cart),
	}
	switch step {
	case stepEmail:
		return renderFragment("commerce-step-email.html", data)
	case stepAddress:
		return renderFragment(addressFragment(def.code), data)
	case stepShipping:
		options, err := s.client.ListShippingOptions(ctx, cart.ID)
		if err != nil {
			return nil, err
		}
		data["Options"] = buildShippingOptions(options, def.currency)
		return renderFragment("commerce-step-shipping.html", data)
	case stepPayment:
		regionID, err := s.region(ctx)
		if err != nil {
			return nil, err
		}
		providers, updated, err := s.buildPaymentProviders(ctx, regionID, cart)
		if err != nil {
			return nil, err
		}
		data["Providers"] = providers
		data["Cart"] = updated
		data["View"] = buildCartView(updated)
		return renderFragment("commerce-step-payment.html", data)
	}
	return nil, errInvalidStep
}

// addressFragment picks the region-specific address form, or the generic one.
func addressFragment(region string) string {
	specific := "commerce-address-" + region + ".html"
	if _, err := pages.ReadFile("pages/" + specific); err == nil {
		return specific
	}
	return "commerce-address.html"
}

// --------------------------------------------------------------- payment

// ensureManualPayment makes sure the cart has a manual payment session.
func (s *Commerce) ensureManualPayment(ctx context.Context, cart *Cart) (*Cart, error) {
	if cart.PaymentCollection != nil {
		for _, session := range cart.PaymentCollection.PaymentSessions {
			if session.ProviderID == "pp_system_default" {
				return cart, nil
			}
		}
	}
	collectionID := ""
	if cart.PaymentCollection != nil {
		collectionID = cart.PaymentCollection.ID
	} else {
		collection, err := s.client.CreatePaymentCollection(ctx, cart.ID)
		if err != nil {
			return nil, err
		}
		collectionID = collection.ID
	}
	if _, err := s.client.InitializePaymentSession(ctx, collectionID, "pp_system_default"); err != nil {
		return nil, err
	}
	return s.client.GetCart(ctx, cart.ID)
}

// --------------------------------------------------------------- confirmation

func (s *Commerce) setConfirmationCookie(c *echo.Context, displayID int) {
	c.SetCookie(&http.Cookie{
		Name:     confirmationCookie,
		Value:    signConfirmation(displayID),
		Path:     cfgCheckoutPath,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   !s.Config.IsDev(),
		MaxAge:   30 * 60,
	})
}

func (s *Commerce) confirmationValid(c *echo.Context, displayID int) bool {
	cookie, err := c.Cookie(confirmationCookie)
	if err != nil {
		return false
	}
	expected := signConfirmation(displayID)
	return hmac.Equal([]byte(cookie.Value), []byte(expected))
}

func signConfirmation(displayID int) string {
	mac := hmac.New(sha256.New, confirmationKey)
	mac.Write([]byte(strconv.Itoa(displayID)))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// --------------------------------------------------------------- view models

type shippingOptionView struct {
	ID    string
	Name  string
	Price string
}

type addressView struct {
	FirstName  string
	LastName   string
	Address1   string
	Address2   string
	City       string
	Province   string
	PostalCode string
	Phone      string
}

func cartAddress(cart *Cart) addressView {
	if cart == nil || cart.ShippingAddress == nil {
		return addressView{}
	}
	a := cart.ShippingAddress
	return addressView{
		FirstName: a.FirstName, LastName: a.LastName, Address1: a.Address1,
		Address2: a.Address2, City: a.City, Province: a.Province,
		PostalCode: a.PostalCode, Phone: a.Phone,
	}
}

func buildShippingOptions(options []ShippingOption, currency string) []shippingOptionView {
	views := make([]shippingOptionView, 0, len(options))
	for _, opt := range options {
		price := ""
		if opt.Amount != "" {
			price = opt.Amount.String() + " " + strings.ToUpper(currency)
		}
		views = append(views, shippingOptionView{ID: opt.ID, Name: opt.Name, Price: price})
	}
	return views
}

// completeErrorMessage reads the failure Medusa answered with.
func completeErrorMessage(result *CompleteResult) string {
	if result != nil && result.Error != nil && result.Error.Message != "" {
		return result.Error.Message
	}
	return "The order could not be placed."
}
