// Package analytics reads the third-party integrations an editor configured in
// the CMS, so the layout can load them.
//
// It knows which integrations exist and which apply here. It does not know what
// any of them mean: turning "posthog" into a loaded script is the browser
// plugin's job, and turning it into markup is the template's. Keeping those
// apart is what lets a key be data while the code that renders it stays code.
package analytics

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"__MODULE__/internal/cms"
	"__MODULE__/internal/config"
	"__MODULE__/internal/views"
)

// model is the collection the Analytics Cockpit addon installs.
const model = "analyticsIntegrations"

// readTimeout bounds the CMS call. It happens during a cold page render, which
// is already bounded, but analytics must never be the slowest thing on a page.
const readTimeout = 5 * time.Second

// Reader answers what the templates should load.
type Reader struct {
	cms *cms.Client
	log *slog.Logger

	// environment is this deployment's APP_ENV, matched against each entry's
	// own setting so development traffic stays out of a client's account.
	environment string
}

// Environment names an entry can be scoped to. APP_ENV is free text and
// deployments spell the same idea half a dozen ways, so it is folded into one
// of these three before anything is compared.
const (
	EnvDevelopment = "development"
	EnvQA          = "qa"
	EnvProduction  = "production"
)

// aliases fold the names deployments actually use.
//
// The one that matters is the QA row. Without it "anything that is not
// development" means production, so a staging or acceptance site would load
// the client's production keys and quietly fill their real analytics with
// test traffic. That is worse than no tracking at all, because the data looks
// legitimate.
var aliases = map[string]string{
	"development": EnvDevelopment,
	"dev":         EnvDevelopment,
	"local":       EnvDevelopment,

	"qa":         EnvQA,
	"staging":    EnvQA,
	"stage":      EnvQA,
	"acceptance": EnvQA,
	"uat":        EnvQA,
	"test":       EnvQA,
	"testing":    EnvQA,
}

// Environment folds an APP_ENV value into the three this feature reasons about.
// Anything unrecognised - including empty - is production, which is the
// fail-safe reading: an unknown environment gets the production keys only if
// nobody said otherwise, and never gets development's.
func Environment(appEnv string) string {
	if folded, ok := aliases[strings.ToLower(strings.TrimSpace(appEnv))]; ok {
		return folded
	}
	return EnvProduction
}

func New(c *cms.Client, cfg config.Config, log *slog.Logger) *Reader {
	// Deliberately not config.IsDev(): that decides whether the cache-purge
	// endpoint may skip its token, and folding staging into "dev" there would
	// leave purging unauthenticated on a staging site. The two questions look
	// alike and must not share an answer.
	return &Reader{cms: c, log: log, environment: Environment(cfg.Environment)}
}

// Integrations returns what applies to this environment, in a shape the
// templates can render.
//
// Never returns an error: analytics is not a reason for a visitor to see a
// broken page. A CMS that cannot be reached, a collection that does not exist
// because the addon is not installed, and a collection with nothing in it are
// all simply "nothing to load", with the first logged.
func (r *Reader) Integrations() []views.Integration {
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	res, err := r.cms.Items(ctx, model, cms.Query{
		// Only "enabled" is filtered by the CMS: it is a plain equality that
		// Cockpit passes straight to the datastore. The environment match is
		// done here instead, because it is a two-way comparison ("all" or this
		// one) and expressing it as a remote query would be trading a line of
		// obvious Go for an assumption about how Cockpit forwards filters.
		Filter: map[string]any{"enabled": true},
		Sort:   map[string]int{"provider": 1},
		Limit:  50,
	})
	if err != nil {
		// A missing collection is the normal state of a project without the
		// addon, so it is not worth a warning; anything else is.
		if !errors.Is(err, cms.ErrNotFound) {
			r.log.Warn("could not read analytics integrations; loading none", "err", err)
		}
		return nil
	}

	out := make([]views.Integration, 0, len(res.Items))

	for _, item := range res.Items {
		provider, _ := item["provider"].(string)
		if provider == "" {
			continue
		}
		if !r.appliesHere(item["environments"]) {
			continue
		}

		config, _ := item["config"].(map[string]any)
		if len(config) == 0 {
			// An entry with no configuration cannot load anything, and a
			// half-configured provider is worse than an absent one.
			r.log.Warn("analytics integration has no configuration; skipping", "provider", provider)
			continue
		}

		out = append(out, views.Integration{Provider: provider, Config: config})
	}

	return out
}

// appliesHere decides whether an entry covers this deployment. An entry with
// nothing set applies everywhere, which is the forgiving reading for an older
// entry written before the field existed.
func (r *Reader) appliesHere(value any) bool {
	applies, _ := value.(string)
	applies = strings.TrimSpace(applies)

	if applies == "" || applies == "all" {
		return true
	}
	return applies == r.environment
}
