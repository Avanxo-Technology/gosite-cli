package commerce

import (
	"context"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/labstack/echo/v5"
)

// paymentRenderer is one entry of the registry (addon design D8): the kind of
// UI a provider needs. Adding a provider later is adding a row and a template.
type paymentRenderer struct {
	Kind     string // manual | embedded | redirect
	Template string // fragment file for embedded/redirect
}

// paymentRenderers is keyed by provider id prefix, because Medusa ids are
// prefixed (pp_stripe_stripe, pp_wompi_wompi).
var paymentRenderers = map[string]paymentRenderer{
	"pp_system_default": {Kind: "manual"},
	"pp_stripe_":        {Kind: "embedded", Template: "commerce-pay-stripe.html"},
	"pp_wompi_":         {Kind: "redirect", Template: "commerce-pay-wompi.html"},
}

// paymentProviderView is what the payment step renders per provider.
type paymentProviderView struct {
	ID             string
	Kind           string
	Template       string
	ClientSecret   string
	PublishableKey string
	CheckoutURL    string
}

func rendererFor(providerID string) (paymentRenderer, bool) {
	// Exact match first (the manual provider), then longest matching prefix.
	if r, ok := paymentRenderers[providerID]; ok {
		return r, true
	}
	best := ""
	for prefix := range paymentRenderers {
		if strings.HasPrefix(providerID, prefix) && len(prefix) > len(best) {
			best = prefix
		}
	}
	if best == "" {
		return paymentRenderer{}, false
	}
	return paymentRenderers[best], true
}

// buildPaymentProviders lists the renderable providers for the region, ensuring
// a payment session for each so embedded/redirect data (client secret, checkout
// URL) is available. Providers with no renderer are hidden and logged once.
func (s *Commerce) buildPaymentProviders(ctx context.Context, regionID string, cart *Cart) ([]paymentProviderView, *Cart, error) {
	providers, err := s.client.ListPaymentProviders(ctx, regionID)
	if err != nil {
		return nil, cart, err
	}
	current := cart
	views := make([]paymentProviderView, 0, len(providers))
	for _, p := range providers {
		renderer, ok := rendererFor(p.ID)
		if !ok {
			s.logUnknownProvider(p.ID)
			continue
		}
		view := paymentProviderView{ID: p.ID, Kind: renderer.Kind, Template: renderer.Template}
		if renderer.Kind != "manual" {
			updated, err := s.ensureSession(ctx, current, p.ID)
			if err != nil {
				return nil, cart, err
			}
			current = updated
			if session := findSession(current, p.ID); session != nil {
				view.ClientSecret = stringValue(session.Data["client_secret"])
				view.CheckoutURL = stringValue(session.Data["checkout_url"])
			}
		}
		view.PublishableKey = strings.TrimSpace(os.Getenv("STRIPE_PUBLISHABLE_KEY"))
		views = append(views, view)
	}
	return views, current, nil
}

// ensureSession makes sure the cart has a payment session for the provider.
func (s *Commerce) ensureSession(ctx context.Context, cart *Cart, providerID string) (*Cart, error) {
	if findSession(cart, providerID) != nil {
		return cart, nil
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
	if _, err := s.client.InitializePaymentSession(ctx, collectionID, providerID); err != nil {
		return nil, err
	}
	return s.client.GetCart(ctx, cart.ID)
}

func findSession(cart *Cart, providerID string) *PaymentSession {
	if cart == nil || cart.PaymentCollection == nil {
		return nil
	}
	for i := range cart.PaymentCollection.PaymentSessions {
		if cart.PaymentCollection.PaymentSessions[i].ProviderID == providerID {
			return &cart.PaymentCollection.PaymentSessions[i]
		}
	}
	return nil
}

// CheckoutPayment re-renders the payment step after the visitor picks a
// provider, so its session exists before the UI is shown.
func (s *Commerce) CheckoutPayment(c *echo.Context) error {
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
	if !isHtmx(c) {
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}
	html, err := s.renderStep(ctx, cart, stepPayment, "")
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not load the payment", err)
	}
	c.Response().Header().Set("Content-Type", "text/html; charset=utf-8")
	return c.HTMLBlob(http.StatusOK, html)
}

// ReturnRoute is where a redirect provider (Wompi) sends the buyer back. It
// completes the cart when the payment is approved, shows a pending page while
// the transaction settles, and keeps the cart on failure.
func (s *Commerce) ReturnRoute(c *echo.Context) error {
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

	status := paymentStatus(cart)
	switch status {
	case "authorized", "captured":
		return s.completeFromReturn(c, ctx, cart)
	case "pending", "":
		return s.renderStatusPage(c, cart, "pending")
	default:
		return s.renderStatusPage(c, cart, "failed")
	}
}

func (s *Commerce) completeFromReturn(c *echo.Context, ctx context.Context, cart *Cart) error {
	result, err := s.client.CompleteCart(ctx, cart.ID)
	if err != nil {
		return s.h.Reply(c).Fail(http.StatusBadGateway, "could not complete the order", err)
	}
	if result.IsOrder() {
		s.clearCartCookie(c)
		s.setConfirmationCookie(c, result.Order.DisplayID)
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath+"/gracias/"+strconv.Itoa(result.Order.DisplayID))
	}
	// Already completed by the webhook: treat as success.
	if cart.CompletedAt != nil {
		s.clearCartCookie(c)
		return c.Redirect(http.StatusSeeOther, cfgCheckoutPath)
	}
	return s.renderStatusPage(c, cart, "failed")
}

// paymentStatus reads the most advanced session status on the cart.
func paymentStatus(cart *Cart) string {
	if cart == nil || cart.PaymentCollection == nil {
		return ""
	}
	rank := map[string]int{"": 0, "pending": 1, "requires_action": 1, "authorized": 2, "captured": 3, "error": 4}
	best := ""
	for _, session := range cart.PaymentCollection.PaymentSessions {
		if rank[session.Status] > rank[best] {
			best = session.Status
		}
	}
	return best
}

func (s *Commerce) renderStatusPage(c *echo.Context, cart *Cart, status string) error {
	data := map[string]any{
		"Title":  "Payment",
		"Path":   cfgCheckoutPath,
		"Status": status,
		"IsDev":  s.Config.IsDev(),
	}
	var buf strings.Builder
	if err := s.Renderer.Page(&buf, "commerce-payment-status", data); err != nil {
		return s.h.Reply(c).Fail(http.StatusInternalServerError, "could not render the payment", err)
	}
	return s.h.Reply(c).Page([]byte(buf.String()), false)
}

func (s *Commerce) logUnknownProvider(providerID string) {
	loggedUnknownMu.Lock()
	seen := loggedUnknownRender[providerID]
	loggedUnknownRender[providerID] = true
	loggedUnknownMu.Unlock()
	if !seen {
		s.Log.Warn("commerce: no renderer for payment provider; hiding it", "provider", providerID)
	}
}

func stringValue(v any) string {
	s, _ := v.(string)
	return s
}
