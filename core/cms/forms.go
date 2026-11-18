package cms

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
)

// ErrRecaptcha means the Forms addon refused a request because its reCAPTCHA
// token was missing or did not pass the form's settings. The visitor can try
// again; nothing was stored.
var ErrRecaptcha = errors.New("forms: recaptcha rejected")

// Recaptcha is a visitor's reCAPTCHA v3 token and the action the page asked
// Google for. The Forms addon verifies it when the form sets
// recaptchaMinScore.
type Recaptcha struct {
	Token  string `json:"token"`
	Action string `json:"action"`
}

// Submission is a form submission for the Forms addon. Honeypot is the value
// of the form's hidden _hp field: a non-empty one makes the addon drop the
// submission while it answers as if it had stored it.
type Submission struct {
	Form string
	Data map[string]string
	// Fields are extra data fields of any JSON value (an object, a number),
	// merged over Data. The Forms addon keeps nested objects two levels deep.
	Fields    map[string]any
	Honeypot  string
	Recaptcha *Recaptcha
}

// FormSettings is the part of a form's settings a site may read.
type FormSettings struct {
	Form         string              `json:"form"`
	Label        string              `json:"label"`
	FieldOptions map[string][]string `json:"fieldOptions"`
}

type formsReply struct {
	Success bool   `json:"success"`
	Error   string `json:"error"`
	ID      string `json:"_id"`
}

// Submit posts a submission to the Forms addon, which stores it and sends the
// form's notifications. It returns the stored entry's ID, which is empty when
// the honeypot was filled. A reCAPTCHA refusal is ErrRecaptcha.
func (c *Client) Submit(ctx context.Context, s Submission) (string, error) {
	data := make(map[string]any, len(s.Data)+len(s.Fields))
	for k, v := range s.Data {
		data[k] = v
	}
	for k, v := range s.Fields {
		data[k] = v
	}
	body := map[string]any{"form": s.Form, "data": data, "_hp": s.Honeypot}
	if s.Recaptcha != nil {
		body["recaptcha"] = s.Recaptcha
	}
	// The receiver is public: it authenticates nobody, so no api-key is sent.
	return c.forms(ctx, http.MethodPost, "/forms/api/submit", body, false)
}

// UpdateSubmission merges fields into the data of a stored submission, through
// the Forms addon: the fields are sanitized like a new submission's, the
// fields it does not receive are kept, and nothing is sent to the form's
// notifications. Pass the visitor's reCAPTCHA token when the update comes
// from a visitor's request; nil skips the check. It needs an API token with
// forms/manage.
func (c *Client) UpdateSubmission(ctx context.Context, id string, fields map[string]string, rc *Recaptcha) error {
	if id == "" {
		return errors.New("forms: update without a submission ID")
	}
	body := map[string]any{"data": fields}
	if rc != nil {
		body["recaptcha"] = rc
	}
	_, err := c.forms(ctx, http.MethodPatch, "/api/forms/submissions/"+url.PathEscape(id), body, true)
	return err
}

// FormSettings returns a form's label and the choices of its fields. A form
// without settings has an empty FieldOptions; a CMS whose Forms addon predates
// the endpoint answers ErrNotFound.
func (c *Client) FormSettings(ctx context.Context, form string) (FormSettings, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/api/forms/settings/"+url.PathEscape(form), nil)
	if err != nil {
		return FormSettings{}, err
	}
	req.Header.Set("api-key", c.token)
	req.Header.Set("Accept", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		return FormSettings{}, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound {
		return FormSettings{}, fmt.Errorf("%w: forms settings for %s", ErrNotFound, form)
	}
	if res.StatusCode != http.StatusOK {
		return FormSettings{}, fmt.Errorf("forms settings for %s: cockpit returned %s: %s", form, res.Status, bodySnippet(res.Body))
	}
	// PHP encodes an empty array as [], not {}: fieldOptions is read raw so
	// that both mean "no choices".
	var raw struct {
		Form         string          `json:"form"`
		Label        string          `json:"label"`
		FieldOptions json.RawMessage `json:"fieldOptions"`
	}
	if err := json.NewDecoder(res.Body).Decode(&raw); err != nil {
		return FormSettings{}, fmt.Errorf("forms settings for %s: %w", form, err)
	}
	out := FormSettings{Form: raw.Form, Label: raw.Label, FieldOptions: map[string][]string{}}
	if opts := bytes.TrimSpace(raw.FieldOptions); len(opts) > 0 && string(opts) != "[]" && string(opts) != "null" {
		if err := json.Unmarshal(opts, &out.FieldOptions); err != nil {
			return FormSettings{}, fmt.Errorf("forms settings for %s: fieldOptions: %w", form, err)
		}
	}
	return out, nil
}

func (c *Client) forms(ctx context.Context, method, path string, body any, auth bool) (string, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if auth {
		req.Header.Set("api-key", c.token)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()

	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	if err != nil {
		return "", err
	}
	var out formsReply
	jsonErr := json.Unmarshal(data, &out)
	if res.StatusCode == http.StatusForbidden && out.Error == "recaptcha" {
		return "", ErrRecaptcha
	}
	if res.StatusCode == http.StatusNotFound {
		return "", fmt.Errorf("%w: %s %s", ErrNotFound, method, path)
	}
	if res.StatusCode != http.StatusOK || jsonErr != nil || !out.Success {
		detail := out.Error
		if detail == "" {
			detail = strings.TrimSpace(string(data[:min(len(data), 512)]))
		}
		return "", fmt.Errorf("forms %s %s: %s: %s", method, path, res.Status, detail)
	}
	return out.ID, nil
}

func bodySnippet(r io.Reader) string {
	var b bytes.Buffer
	io.CopyN(&b, r, 512)
	return strings.TrimSpace(b.String())
}
