package commerce

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"
)

// checkoutCookie adds an item and returns the cart cookie.
func checkoutCookie(t *testing.T, e *echo.Echo, fake *cartFake) *http.Cookie {
	t.Helper()
	_ = fake
	rec := post(t, e, "/_commerce/add", "variant_id=prod_1_v1&handle=tee&quantity=1", true, nil)
	cookie := responseCookie(t, rec, cartCookieName)
	if cookie == nil {
		t.Fatal("no cart cookie after add")
	}
	return cookie
}

func TestCheckoutRequiresANonEmptyCart(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)

	rec := get(t, e, "/checkout")
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/tienda" {
		t.Fatalf("empty checkout = %d %q, want a redirect to the PLP", rec.Code, rec.Header().Get("Location"))
	}
}

func TestCheckoutStepMachine(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)
	cookie := checkoutCookie(t, e, fake)

	// Step 1: email.
	page := getWithCookie(t, e, "/checkout", cookie)
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "/_commerce/checkout/email") {
		t.Fatalf("checkout did not start at the email step: %d", page.Code)
	}

	// Step 2: address (region co -> the Colombian labels).
	rec := post(t, e, "/_commerce/checkout/email", "email=ada@example.com", true, cookie)
	if !strings.Contains(rec.Body.String(), "Departamento") {
		t.Fatalf("email step did not advance to the co address form: %s", rec.Body.String())
	}

	// Step 3: shipping.
	rec = post(t, e, "/_commerce/checkout/address",
		"first_name=Ada&last_name=Lovelace&address_1=Calle 1&city=Bogota&province=Cundinamarca", true, cookie)
	if !strings.Contains(rec.Body.String(), "so_1") {
		t.Fatalf("address step did not advance to shipping: %s", rec.Body.String())
	}

	// Step 4: payment, and the unrenderable provider is hidden.
	rec = post(t, e, "/_commerce/checkout/shipping", "option_id=so_1", true, cookie)
	if !strings.Contains(rec.Body.String(), "Place order") {
		t.Fatalf("shipping step did not advance to payment: %s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "pp_unknown") {
		t.Fatalf("payment step listed a provider with no renderer: %s", rec.Body.String())
	}
}

func TestCompletePlacesOrderAndShowsConfirmation(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)
	cookie := checkoutCookie(t, e, fake)
	advanceToPayment(t, e, cookie)

	rec := post(t, e, "/_commerce/checkout/complete", "", true, cookie)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/checkout/gracias/1" {
		t.Fatalf("complete = %d %q, want a redirect to the thanks page", rec.Code, rec.Header().Get("Location"))
	}
	orderCookie := responseCookie(t, rec, confirmationCookie)
	if orderCookie == nil {
		t.Fatal("complete did not set the confirmation cookie")
	}
	if c := responseCookie(t, rec, cartCookieName); c == nil || c.MaxAge >= 0 {
		t.Fatalf("complete did not clear the cart cookie: %+v", c)
	}

	thanks := getWithCookie(t, e, "/checkout/gracias/1", orderCookie)
	if thanks.Code != http.StatusOK || !strings.Contains(thanks.Body.String(), "#1") {
		t.Fatalf("thanks page = %d: %s", thanks.Code, thanks.Body.String())
	}
}

func TestConfirmationRequiresTheCookie(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)
	if rec := get(t, e, "/checkout/gracias/1"); rec.Code != http.StatusNotFound {
		t.Fatalf("thanks without cookie = %d, want 404", rec.Code)
	}
}

func TestCompleteFailureKeepsTheCart(t *testing.T) {
	fake := newCartFake(t)
	e := newCartApp(t, fake)
	cookie := checkoutCookie(t, e, fake)
	advanceToPayment(t, e, cookie)
	fake.completeFails = true

	rec := post(t, e, "/_commerce/checkout/complete", "", true, cookie)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "payment not authorized") {
		t.Fatalf("failed complete = %d: %s", rec.Code, rec.Body.String())
	}
	if c := responseCookie(t, rec, cartCookieName); c != nil {
		t.Fatalf("failed complete changed the cart cookie: %+v", c)
	}
	if responseCookie(t, rec, confirmationCookie) != nil {
		t.Fatal("failed complete set a confirmation cookie")
	}
}

// advanceToPayment walks the cart to the payment step.
func advanceToPayment(t *testing.T, e *echo.Echo, cookie *http.Cookie) {
	t.Helper()
	post(t, e, "/_commerce/checkout/email", "email=ada@example.com", true, cookie)
	post(t, e, "/_commerce/checkout/address",
		"first_name=Ada&last_name=Lovelace&address_1=Calle 1&city=Bogota&province=Cundinamarca", true, cookie)
	post(t, e, "/_commerce/checkout/shipping", "option_id=so_1", true, cookie)
}

func getWithCookie(t *testing.T, e *echo.Echo, path string, cookie *http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	return rec
}
