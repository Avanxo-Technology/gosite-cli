package commerce

import (
	"encoding/json"
	"html/template"
	"net/http"
	"strings"
)

// Meta's standard event names. The browser plugin forwards them unchanged, and
// analytics.js reads them from a data block or an htmx trigger.
const (
	eventViewContent      = "ViewContent"
	eventAddToCart        = "AddToCart"
	eventInitiateCheckout = "InitiateCheckout"
)

// analyticsTrigger is the htmx trigger name analytics.js listens for.
const analyticsTrigger = "analytics:event"

// analyticsEvent is the payload analytics.js reads: {"event": ..., "properties": {...}}.
type analyticsEvent struct {
	Event      string          `json:"event"`
	Properties eventProperties `json:"properties"`
}

// eventProperties is a fixed struct, not a map, so no other key can reach the
// payload.
type eventProperties struct {
	Value       Amount   `json:"value"`
	Currency    string   `json:"currency"`
	ContentIDs  []string `json:"content_ids"`
	ContentType string   `json:"content_type"`
	NumItems    int      `json:"num_items"`
}

// productEvent builds an event about products. Medusa amounts are already in
// the currency's major unit, so the value is passed through unscaled. It
// returns nil without a price: an empty json.Number would serialise as 0.
func productEvent(name string, value Amount, currency string, variantIDs []string, numItems int) *analyticsEvent {
	if value == "" {
		return nil
	}
	return &analyticsEvent{
		Event: name,
		Properties: eventProperties{
			Value:       value,
			Currency:    strings.ToUpper(currency),
			ContentIDs:  variantIDs,
			ContentType: "product",
			NumItems:    numItems,
		},
	}
}

// pdpEvent is ViewContent for the variant the product page shows first. The buy
// island loads that same variant when no variant is chosen (pickVariant("")).
// The event holds only store data, never a visitor's, because the page is cached.
func pdpEvent(product Product, currency string) *analyticsEvent {
	variant := pickVariant(product, "")
	if variant == nil || variant.CalculatedPrice == nil {
		return nil
	}
	return productEvent(eventViewContent, variant.CalculatedPrice.CalculatedAmount, currency, []string{variant.ID}, 1)
}

// addToCartEvent is AddToCart for the variant just added. The value is the unit
// price, as the spec asks; num_items is the quantity added. buyData resolves an
// unknown variant to the first one, so the event is sent only when they match.
func addToCartEvent(data buyData, variantID string, quantity int) *analyticsEvent {
	if data.VariantID != variantID {
		return nil
	}
	return productEvent(eventAddToCart, data.unitPrice, data.Currency, []string{variantID}, quantity)
}

// checkoutEvent is InitiateCheckout for the cart's lines and total.
func checkoutEvent(cart *Cart, currency string) *analyticsEvent {
	ids := make([]string, 0, len(cart.Items))
	items := 0
	for _, item := range cart.Items {
		ids = append(ids, item.VariantID)
		items += item.Quantity
	}
	return productEvent(eventInitiateCheckout, cart.Total, currency, ids, items)
}

// eventBlock renders an event as the body of a data block. json.Marshal escapes
// <, > and & inside strings, so the output cannot close the script element. A
// nil event renders nothing.
func eventBlock(ev *analyticsEvent) (template.JS, error) {
	if ev == nil {
		return "", nil
	}
	raw, err := json.Marshal(ev)
	if err != nil {
		return "", err
	}
	return template.JS(raw), nil //nolint:gosec // JSON from json.Marshal; HTML characters are escaped
}

// setEventTrigger sets the analytics trigger on an htmx response. An existing
// HX-Trigger is merged, not replaced: a JSON object gains the key, and a plain
// comma-separated list of event names keeps each name with an empty detail.
func setEventTrigger(h http.Header, ev *analyticsEvent) error {
	if ev == nil {
		return nil
	}
	triggers := map[string]json.RawMessage{}
	if existing := strings.TrimSpace(h.Get("HX-Trigger")); existing != "" {
		if err := json.Unmarshal([]byte(existing), &triggers); err != nil {
			for _, name := range strings.Split(existing, ",") {
				if name = strings.TrimSpace(name); name != "" {
					triggers[name] = json.RawMessage("{}")
				}
			}
		}
	}
	raw, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	triggers[analyticsTrigger] = raw
	out, err := json.Marshal(triggers)
	if err != nil {
		return err
	}
	h.Set("HX-Trigger", string(out))
	return nil
}
