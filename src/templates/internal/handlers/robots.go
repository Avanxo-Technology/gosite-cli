package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// Robots serves /robots.txt from the webapp singleton.
func (h *Handlers) Robots(c *echo.Context) error {
	content := "User-agent: *\nAllow: /\n"

	if h.SEO != nil {
		config := h.SEO.GetWebappConfig()
		if config != nil && config.RobotsTxt != "" {
			content = config.RobotsTxt
		}
	}

	return (*c).Blob(http.StatusOK, "text/plain", []byte(content))
}
