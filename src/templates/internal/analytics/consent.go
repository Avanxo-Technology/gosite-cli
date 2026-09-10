package analytics

import (
	"context"
	"errors"
	"strings"

	"__MODULE__/internal/cms"
	"__MODULE__/internal/views"
)

// consentModel is the singleton the Analytics Cockpit addon installs alongside
// the integrations collection. It lives in the same addon on purpose: the thing
// being gated is what that addon stores, and a separate addon would let a
// project install tracking with no banner.
const consentModel = "analyticsConsent"

// Consent returns the banner's configuration, or nil when this site has none.
//
// Nil is the honest answer for three different situations - the addon is not
// installed, the singleton was never filled in, or the CMS cannot be reached -
// and the browser treats all three the same way: no consent given, so nothing
// optional loads. That is the fail-closed reading, and it is the opposite of
// what the code did before this existed.
//
// Like Integrations it never returns an error. A banner that cannot be
// configured must not take a page down; it must take the tracking down.
func (r *Reader) Consent() *views.Consent {
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	item, err := r.cms.SingletonErr(ctx, consentModel)
	if err != nil {
		if !errors.Is(err, cms.ErrNotFound) {
			r.log.Warn("could not read the consent settings; asking for no consent and loading nothing", "err", err)
		}
		return nil
	}

	if len(item) == 0 {
		return nil
	}

	enabled, _ := item["enabled"].(bool)

	if !enabled {
		// Explicitly off is not the same as absent, but the browser must treat
		// it the same. Saying so once here beats the browser having to guess.
		r.log.Info("consent is configured but disabled; no gated provider will load")
		return nil
	}

	return &views.Consent{
		Enabled:     true,
		CopyVersion: text(item, "copyVersion", "1"),

		Title:       text(item, "title", "Usamos cookies"),
		Body:        text(item, "body", "Utilizamos cookies para entender cómo se usa este sitio. Tú decides cuáles aceptar."),
		AcceptLabel: text(item, "acceptLabel", "Aceptar todo"),
		RejectLabel: text(item, "rejectLabel", "Rechazar todo"),
		PrefsLabel:  text(item, "prefsLabel", "Preferencias"),
		SaveLabel:   text(item, "saveLabel", "Guardar mis preferencias"),

		PolicyLabel: text(item, "policyLabel", "Política de privacidad"),
		PolicyURL:   text(item, "policyUrl", ""),

		NecessaryLabel:       text(item, "necessaryLabel", "Necesarias"),
		NecessaryDescription: text(item, "necessaryDescription", "Imprescindibles para que el sitio funcione. Siempre activas."),
		AnalyticsLabel:       text(item, "analyticsLabel", "Analítica"),
		AnalyticsDescription: text(item, "analyticsDescription", "Nos ayudan a entender qué páginas resultan útiles."),
		MarketingLabel:       text(item, "marketingLabel", "Marketing"),
		MarketingDescription: text(item, "marketingDescription", "Se usan para medir y orientar la publicidad."),
	}
}

// text reads a string field, falling back when an editor left it empty.
//
// Defaults live here rather than in the template because the banner is a legal
// control: a site that enabled consent and left a label blank must still show
// a usable button, not an empty one.
//
// They are in Spanish, matching the copy the addon seeds into the singleton
// when it creates it. The two have to agree: an English fallback beside seeded
// Spanish would mean deleting one field produced a banner in two languages.
// A site in another language overwrites the copy in the CMS, which is where
// that decision belongs.
func text(item cms.Content, key, fallback string) string {
	s, _ := item[key].(string)
	s = strings.TrimSpace(s)

	if s == "" {
		return fallback
	}
	return s
}
