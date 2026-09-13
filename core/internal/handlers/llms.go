package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// LLMs serves /llms.txt: the LLM Text field of the webapp singleton, verbatim.
//
// Deliberately not templated or decorated. The field is plain text in Cockpit
// precisely so an editor controls the whole document, and a crawler receives
// exactly what they wrote.
func (h *Handlers) LLMs(c *echo.Context) error {
	if h.SEO == nil {
		return (*c).NoContent(http.StatusNotFound)
	}

	config := h.SEO.GetWebappConfig()
	if config == nil || config.LLMText == "" {
		return (*c).NoContent(http.StatusNotFound)
	}

	return (*c).Blob(http.StatusOK, "text/plain; charset=utf-8", []byte(config.LLMText))
}
