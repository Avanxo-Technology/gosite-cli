// Package deprecate is core's side of the deprecation policy: a public name
// keeps working for at least one minor release after it is replaced, and the
// process says so once instead of on every request.
package deprecate

import (
	"log/slog"
	"sync"
)

var warned sync.Map

// Warn logs that old is deprecated in favour of replacement, once per process
// for each old name. A nil logger uses slog's default.
func Warn(log *slog.Logger, old, replacement string) {
	if _, seen := warned.LoadOrStore(old, true); seen {
		return
	}
	if log == nil {
		log = slog.Default()
	}
	log.Warn("deprecated: "+old+" still works but will be removed in a future major version",
		"deprecated", old, "use", replacement)
}

// reset forgets every warning. Tests only.
func reset() { warned = sync.Map{} }
