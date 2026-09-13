package main

import (
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/gositetest"
)

// The theme's contract with core: every slot called exactly once, and every
// page renders.
func TestTheme(t *testing.T) {
	gositetest.CheckTheme(t, theme())
}
