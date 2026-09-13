package gosite

import (
	"os"
	"strings"
	"testing"
)

// Content is read through the Cockpit REST client only. A Mongo driver in the
// module is how a site ends up with a second, cache-less, schema-coupled way
// to read the CMS (lnequipos-v2 did exactly that), so its arrival fails here.
func TestNoMongoDriver(t *testing.T) {
	for _, file := range []string{"go.mod", "go.sum"} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(strings.ToLower(string(data)), "mongo") {
			t.Errorf("%s references a MongoDB module; read content with the cms client", file)
		}
	}
}
