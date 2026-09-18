package commerce

// regionDef is the Go side of the region table. It mirrors
// services/medusa/src/lib/regions.ts: the storefront needs the currency and
// country to match the Medusa region the seed created, and the locale for
// rendering.
type regionDef struct {
	code     string
	name     string
	currency string
	country  string
	locale   string
}

var regions = map[string]regionDef{
	"co": {code: "co", name: "Colombia", currency: "cop", country: "co", locale: "es-CO"},
	"us": {code: "us", name: "United States", currency: "usd", country: "us", locale: "en-US"},
}

// regionDefForCurrent returns the definition of the configured region.
func regionDefForCurrent() (regionDef, bool) {
	def, ok := regions[currentRegion()]
	return def, ok
}
