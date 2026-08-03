package templates

// Article mirrors the main package projection of a Cockpit item.
type Article struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Excerpt string `json:"excerpt"`
	Slug    string `json:"slug"`
}
