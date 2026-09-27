package commerce

// buyData is what the island renders: one variant's price, stock and add form.
type buyData struct {
	Handle     string
	VariantID  string
	Title      string
	Price      string
	Currency   string
	Stock      int
	StockKnown bool
	InStock    bool
	// Error is shown when an add was refused, e.g. out of stock.
	Error string
}
