package cms

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

type formsCall struct {
	method, path, apiKey string
	body                 map[string]any
}

// formsServer answers like the Forms addon would and records each request.
func formsServer(t *testing.T, status int, reply string) (*Client, *[]formsCall) {
	t.Helper()
	var calls []formsCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		c := formsCall{method: r.Method, path: r.URL.Path, apiKey: r.Header.Get("api-key")}
		json.Unmarshal(raw, &c.body)
		calls = append(calls, c)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		io.WriteString(w, reply)
	}))
	t.Cleanup(srv.Close)
	return New(config.Config{CockpitURL: srv.URL, CockpitToken: "tok"}, slog.New(slog.NewTextHandler(io.Discard, nil))), &calls
}

func TestSubmitReturnsTheEntryID(t *testing.T) {
	c, calls := formsServer(t, http.StatusOK, `{"success":true,"_id":"abc123"}`)
	id, err := c.Submit(t.Context(), Submission{
		Form: "lead", Data: map[string]string{"email": "a@b.co"}, Honeypot: "",
		Recaptcha: &Recaptcha{Token: "t", Action: "scan"},
	})
	if err != nil || id != "abc123" {
		t.Fatalf("id %q, err %v", id, err)
	}
	got := (*calls)[0]
	if got.method != http.MethodPost || got.path != "/forms/api/submit" || got.apiKey != "" {
		t.Errorf("request %s %s api-key %q; want the public receiver without a token", got.method, got.path, got.apiKey)
	}
	rc, _ := got.body["recaptcha"].(map[string]any)
	if got.body["form"] != "lead" || rc["token"] != "t" || rc["action"] != "scan" {
		t.Errorf("body = %v", got.body)
	}
}

func TestSubmitWithoutRecaptchaSendsNone(t *testing.T) {
	c, calls := formsServer(t, http.StatusOK, `{"success":true,"_id":"x"}`)
	if _, err := c.Submit(t.Context(), Submission{Form: "contacto", Data: map[string]string{"a": "b"}}); err != nil {
		t.Fatal(err)
	}
	if _, has := (*calls)[0].body["recaptcha"]; has {
		t.Errorf("body carries a recaptcha key: %v", (*calls)[0].body)
	}
}

func TestRecaptchaRefusalIsErrRecaptcha(t *testing.T) {
	c, _ := formsServer(t, http.StatusForbidden, `{"success":false,"error":"recaptcha"}`)
	_, err := c.Submit(t.Context(), Submission{Form: "lead", Data: map[string]string{"a": "b"}})
	if !errors.Is(err, ErrRecaptcha) {
		t.Fatalf("err = %v, want ErrRecaptcha", err)
	}
	err = c.UpdateSubmission(t.Context(), "abc", map[string]string{"a": "b"}, &Recaptcha{Token: "t", Action: "lead"})
	if !errors.Is(err, ErrRecaptcha) {
		t.Fatalf("update err = %v, want ErrRecaptcha", err)
	}
}

func TestOtherFormsErrorsAreNotRecaptcha(t *testing.T) {
	c, _ := formsServer(t, http.StatusTooManyRequests, `{"success":false,"error":"Too many submissions."}`)
	_, err := c.Submit(t.Context(), Submission{Form: "lead", Data: map[string]string{"a": "b"}})
	if err == nil || errors.Is(err, ErrRecaptcha) {
		t.Fatalf("err = %v, want a plain error", err)
	}
}

func TestUpdateSubmissionGoesThroughTheAddon(t *testing.T) {
	c, calls := formsServer(t, http.StatusOK, `{"success":true,"_id":"abc"}`)
	if err := c.UpdateSubmission(t.Context(), "abc", map[string]string{"status": "no iniciado"}, nil); err != nil {
		t.Fatal(err)
	}
	got := (*calls)[0]
	if got.method != http.MethodPatch || got.path != "/api/forms/submissions/abc" || got.apiKey != "tok" {
		t.Errorf("request %s %s api-key %q", got.method, got.path, got.apiKey)
	}
	if d, _ := got.body["data"].(map[string]any); d["status"] != "no iniciado" {
		t.Errorf("body = %v", got.body)
	}
	if _, has := got.body["recaptcha"]; has {
		t.Errorf("nil Recaptcha sent a recaptcha key: %v", got.body)
	}
}

func TestUpdateSubmissionUnknownIDIsNotFound(t *testing.T) {
	c, _ := formsServer(t, http.StatusNotFound, `{"success":false,"error":"Submission not found."}`)
	if err := c.UpdateSubmission(t.Context(), "nope", map[string]string{"a": "b"}, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	if err := c.UpdateSubmission(t.Context(), "", map[string]string{"a": "b"}, nil); err == nil {
		t.Fatal("an empty ID was sent")
	}
}

func TestFormSettings(t *testing.T) {
	c, calls := formsServer(t, http.StatusOK, `{"form":"diagnostico","label":"Diagnóstico","fieldOptions":{"necesidad":["Ventas","Marca"]}}`)
	s, err := c.FormSettings(t.Context(), "diagnostico")
	if err != nil {
		t.Fatal(err)
	}
	if s.Label != "Diagnóstico" || len(s.FieldOptions["necesidad"]) != 2 || s.FieldOptions["necesidad"][1] != "Marca" {
		t.Errorf("settings = %+v", s)
	}
	if got := (*calls)[0]; got.path != "/api/forms/settings/diagnostico" || got.apiKey != "tok" {
		t.Errorf("request %s api-key %q", got.path, got.apiKey)
	}
}

// PHP encodes an empty array as []; the addon casts fieldOptions to an object,
// but every empty form of it means "no choices".
func TestFormSettingsEmptyOptions(t *testing.T) {
	for _, reply := range []string{`{"form":"x","label":"x","fieldOptions":{}}`, `{"form":"x","label":"x","fieldOptions":[]}`, `{"form":"x","label":"x","fieldOptions":null}`, `{"form":"x","label":"x"}`} {
		c, _ := formsServer(t, http.StatusOK, reply)
		s, err := c.FormSettings(t.Context(), "x")
		if err != nil {
			t.Fatalf("%s: %v", reply, err)
		}
		if s.FieldOptions == nil || len(s.FieldOptions) != 0 {
			t.Errorf("%s: FieldOptions = %v, want empty and not nil", reply, s.FieldOptions)
		}
	}
}

func TestFormSettingsOldAddonIsNotFound(t *testing.T) {
	c, _ := formsServer(t, http.StatusNotFound, `{"error":"Not found"}`)
	if _, err := c.FormSettings(t.Context(), "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestSingletonErrTellsUnpublishedFromMissing(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		unpublished bool
	}{
		{"unpublished singleton (bare 404)", "", true},
		{"model that does not exist", `{"error":"Model <home> not found"}`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, _ := formsServer(t, http.StatusNotFound, tc.body)
			_, err := c.SingletonErr(t.Context(), "home")
			if !errors.Is(err, ErrNotFound) {
				t.Fatalf("err = %v, want it to match ErrNotFound", err)
			}
			if got := errors.Is(err, ErrUnpublished); got != tc.unpublished {
				t.Errorf("errors.Is(err, ErrUnpublished) = %v, want %v", got, tc.unpublished)
			}
		})
	}
}
