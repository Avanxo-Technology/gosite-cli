package commerce

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"testing"
)

// analyticsBlockPattern matches one event block. The body is lazy, so a stray
// "</script>" inside a block ends the match early and the JSON check fails.
var analyticsBlockPattern = regexp.MustCompile(`(?s)<script type="application/json" data-analytics-event>(.*?)</script>`)

// parseEventBlocks returns the event of every block in the page. It fails when
// an event marker sits outside a well-formed block.
func parseEventBlocks(t *testing.T, body string) []analyticsEvent {
	t.Helper()
	matches := analyticsBlockPattern.FindAllStringSubmatch(body, -1)
	if got := strings.Count(body, "data-analytics-event"); got != len(matches) {
		t.Fatalf("%d event markers but %d well-formed blocks", got, len(matches))
	}
	events := make([]analyticsEvent, 0, len(matches))
	for _, m := range matches {
		var ev analyticsEvent
		if err := json.Unmarshal([]byte(m[1]), &ev); err != nil {
			t.Fatalf("event block is not JSON: %v\n%s", err, m[1])
		}
		events = append(events, ev)
	}
	return events
}

// wireEvent sends an event through the encoding the pages use and reads it back.
func wireEvent(t *testing.T, ev *analyticsEvent) analyticsEvent {
	t.Helper()
	block, err := eventBlock(ev)
	if err != nil {
		t.Fatalf("eventBlock: %v", err)
	}
	var out analyticsEvent
	if err := json.Unmarshal([]byte(block), &out); err != nil {
		t.Fatalf("event is not JSON: %v\n%s", err, block)
	}
	return out
}

const hostileTitle = `Tee "Classic" </script><img src=x onerror=alert(1)>`

func hostileProduct() Product {
	return Product{
		ID:     "prod_x",
		Title:  hostileTitle,
		Handle: "tee-classic",
		Variants: []ProductVariant{{
			ID:              "prod_x_v1",
			Title:           "Default",
			CalculatedPrice: &CalculatedPrice{CalculatedAmount: "59900", CurrencyCode: "cop"},
		}},
	}
}

func TestPDPEventCarriesTheFirstVariant(t *testing.T) {
	product := Product{
		ID: "prod_1", Title: "Tee", Handle: "tee",
		Variants: []ProductVariant{
			{ID: "prod_1_v1", CalculatedPrice: &CalculatedPrice{CalculatedAmount: "40.5"}},
			{ID: "prod_1_v2", CalculatedPrice: &CalculatedPrice{CalculatedAmount: "50"}},
		},
	}
	ev := pdpEvent(product, "usd")
	block, err := eventBlock(ev)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(block), `"value":40.5`) {
		t.Errorf("value is not a JSON number: %s", block)
	}

	got := wireEvent(t, ev)
	p := got.Properties
	if got.Event != eventViewContent || p.Value.String() != "40.5" || p.Currency != "USD" ||
		p.ContentType != "product" || p.NumItems != 1 || len(p.ContentIDs) != 1 || p.ContentIDs[0] != "prod_1_v1" {
		t.Fatalf("ViewContent = %+v", got)
	}
}

func TestPDPBlockParsesWithHostileTitle(t *testing.T) {
	product := hostileProduct()
	analytics, err := eventBlock(pdpEvent(product, "cop"))
	if err != nil {
		t.Fatal(err)
	}
	data := map[string]any{
		"Title":     product.Title,
		"Product":   product,
		"View":      buildProductView(product, "cop"),
		"Currency":  "COP",
		"Analytics": analytics,
	}
	html, err := renderFragment("commerce-pdp.html", data)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	body := string(html)

	if n := strings.Count(body, "<script"); n != 1 {
		t.Fatalf("page has %d <script> elements, want exactly the event block", n)
	}
	if strings.Contains(body, "<img src=x") {
		t.Error("the title's markup reached the page unescaped")
	}
	if !strings.Contains(body, "&lt;/script&gt;") {
		t.Error("the title was not escaped in the heading")
	}
	events := parseEventBlocks(t, body)
	if len(events) != 1 || events[0].Event != eventViewContent || events[0].Properties.Value.String() != "59900" {
		t.Fatalf("events = %+v", events)
	}
}

func TestCheckoutPageHasOneEventBlock(t *testing.T) {
	cart := &Cart{Total: "59900", Items: []LineItem{{VariantID: "prod_1_v1", Quantity: 1}}}
	analytics, err := eventBlock(checkoutEvent(cart, "cop"))
	if err != nil {
		t.Fatal(err)
	}
	html, err := renderFragment("commerce-checkout.html", map[string]any{
		"Title":     "Checkout",
		"Body":      templateHTML([]byte(`<p>step</p>`)),
		"Analytics": analytics,
	})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	body := string(html)
	if n := strings.Count(body, "<script"); n != 1 {
		t.Fatalf("page has %d <script> elements, want exactly the event block", n)
	}
	events := parseEventBlocks(t, body)
	if len(events) != 1 || events[0].Event != eventInitiateCheckout || events[0].Properties.NumItems != 1 {
		t.Fatalf("events = %+v", events)
	}
}

func TestCheckoutEventSumsTheLines(t *testing.T) {
	cart := &Cart{Total: "149700", Items: []LineItem{
		{VariantID: "prod_1_v1", Quantity: 2},
		{VariantID: "prod_2_v1", Quantity: 1},
	}}
	got := wireEvent(t, checkoutEvent(cart, "cop"))
	p := got.Properties
	if got.Event != eventInitiateCheckout || p.Value.String() != "149700" || p.Currency != "COP" ||
		p.NumItems != 3 || strings.Join(p.ContentIDs, ",") != "prod_1_v1,prod_2_v1" {
		t.Fatalf("InitiateCheckout = %+v", got)
	}
}

func TestAddToCartEventUsesUnitPriceAndQuantity(t *testing.T) {
	data := buyData{VariantID: "prod_1_v1", Currency: "COP", unitPrice: "59900"}
	got := wireEvent(t, addToCartEvent(data, "prod_1_v1", 2))
	p := got.Properties
	if got.Event != eventAddToCart || p.Value.String() != "59900" || p.NumItems != 2 ||
		p.Currency != "COP" || len(p.ContentIDs) != 1 || p.ContentIDs[0] != "prod_1_v1" {
		t.Fatalf("AddToCart = %+v", got)
	}
	// buyData answers an unknown variant with the first one; that is not the
	// variant that was added, so no event is sent.
	if addToCartEvent(data, "prod_9_v9", 1) != nil {
		t.Error("an event was built for a variant other than the one added")
	}
}

func TestEventsWithoutAPriceAreOmitted(t *testing.T) {
	noPrice := Product{ID: "prod_1", Variants: []ProductVariant{{ID: "prod_1_v1"}}}
	if pdpEvent(noPrice, "cop") != nil {
		t.Error("ViewContent was built without a price")
	}
	if pdpEvent(Product{ID: "prod_2"}, "cop") != nil {
		t.Error("ViewContent was built for a product with no variant")
	}
	if productEvent(eventAddToCart, "", "cop", []string{"prod_1_v1"}, 1) != nil {
		t.Error("an empty amount would have been sent as 0")
	}
	if block, err := eventBlock(nil); err != nil || block != "" {
		t.Errorf("eventBlock(nil) = %q, %v; want nothing", block, err)
	}
}

func TestSetEventTriggerMergesExistingTriggers(t *testing.T) {
	ev := productEvent(eventAddToCart, "59900", "cop", []string{"prod_1_v1"}, 1)
	cases := []struct {
		name     string
		existing string
		keep     []string
	}{
		{name: "no header"},
		{name: "JSON object", existing: `{"refresh":{"x":1}}`, keep: []string{"refresh"}},
		{name: "plain names", existing: "refresh, cartChanged", keep: []string{"refresh", "cartChanged"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := http.Header{}
			if tc.existing != "" {
				h.Set("HX-Trigger", tc.existing)
			}
			if err := setEventTrigger(h, ev); err != nil {
				t.Fatal(err)
			}
			var triggers map[string]json.RawMessage
			if err := json.Unmarshal([]byte(h.Get("HX-Trigger")), &triggers); err != nil {
				t.Fatalf("HX-Trigger is not JSON: %v", err)
			}
			for _, name := range tc.keep {
				if _, ok := triggers[name]; !ok {
					t.Errorf("existing trigger %q was lost: %s", name, h.Get("HX-Trigger"))
				}
			}
			raw, ok := triggers[analyticsTrigger]
			if !ok {
				t.Fatalf("no %q trigger: %s", analyticsTrigger, h.Get("HX-Trigger"))
			}
			var payload analyticsEvent
			if err := json.Unmarshal(raw, &payload); err != nil {
				t.Fatalf("trigger payload: %v", err)
			}
			if payload.Event != eventAddToCart || payload.Properties.Value.String() != "59900" {
				t.Fatalf("trigger payload = %+v", payload)
			}
			var props map[string]json.RawMessage
			if err := json.Unmarshal(raw, &struct {
				Properties *map[string]json.RawMessage `json:"properties"`
			}{&props}); err != nil {
				t.Fatal(err)
			}
			if _, ok := props["target"]; ok {
				t.Error(`the payload carries a "target" key`)
			}
		})
	}
}

func TestAddHTMXSendsAddToCartTrigger(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=2", true, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("add = %d: %s", rec.Code, rec.Body.String())
	}
	var triggers map[string]analyticsEvent
	if err := json.Unmarshal([]byte(rec.Header().Get("HX-Trigger")), &triggers); err != nil {
		t.Fatalf("HX-Trigger = %q: %v", rec.Header().Get("HX-Trigger"), err)
	}
	got, ok := triggers[analyticsTrigger]
	if !ok {
		t.Fatalf("no analytics trigger in %q", rec.Header().Get("HX-Trigger"))
	}
	p := got.Properties
	if got.Event != eventAddToCart || p.Value.String() != "59900" || p.NumItems != 2 || p.Currency != "COP" ||
		len(p.ContentIDs) != 1 || p.ContentIDs[0] != "prod_1_v1" {
		t.Fatalf("AddToCart = %+v", got)
	}
}

func TestAddWithoutHTMXSendsNoEvent(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", false, nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("no-JS add = %d, want 303", rec.Code)
	}
	if h := rec.Header().Get("HX-Trigger"); h != "" {
		t.Fatalf("no-JS add set HX-Trigger = %q", h)
	}
}

func TestPDPPageServesTheSameEventFromCache(t *testing.T) {
	e := newStorefront(t, true)
	for _, want := range []string{"MISS", "HIT"} {
		rec := get(t, e, "/producto/tee")
		if rec.Header().Get("X-Cache") != want {
			t.Fatalf("X-Cache = %q, want %s", rec.Header().Get("X-Cache"), want)
		}
		events := parseEventBlocks(t, rec.Body.String())
		if len(events) != 1 || events[0].Event != eventViewContent || events[0].Properties.Value.String() != "59900" {
			t.Fatalf("%s page events = %+v", want, events)
		}
	}
}

func TestCheckoutFullPageSendsInitiateCheckoutOnly(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)
	cookie := checkoutCookie(t, e, fake)

	page := getWithCookie(t, e, "/checkout", cookie)
	events := parseEventBlocks(t, page.Body.String())
	if len(events) != 1 || events[0].Event != eventInitiateCheckout || events[0].Properties.Value.String() != "59900" {
		t.Fatalf("checkout page events = %+v", events)
	}

	step := post(t, e, "/_commerce/checkout/email", "email=ada@example.com", true, cookie)
	if strings.Contains(step.Body.String(), "data-analytics-event") {
		t.Fatal("a checkout step fragment carries an event block")
	}
}
