package deprecate

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

func TestWarnOncePerName(t *testing.T) {
	reset()
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil))

	Warn(log, "consent-head", "gosite:head")
	Warn(log, "consent-head", "gosite:head")
	Warn(log, "analytics-body", "gosite:body-start")

	out := buf.String()
	if n := strings.Count(out, "deprecated=consent-head"); n != 1 {
		t.Errorf("consent-head warned %d times, want 1", n)
	}
	if !strings.Contains(out, "use=gosite:head") {
		t.Error("the warning does not name the replacement")
	}
	if !strings.Contains(out, "deprecated=analytics-body") {
		t.Error("a second deprecated name was not warned about")
	}
}
