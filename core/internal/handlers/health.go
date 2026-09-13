package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// Health reports liveness. It checks Redis because the site is unusable
// without it, so an orchestrator restarting the container is the right call.
func (h *Handlers) Health(c *echo.Context) error {
	if err := h.Redis.Ping(c.Request().Context()).Err(); err != nil {
		return h.reply(c).Fail(http.StatusServiceUnavailable, "redis unavailable", err)
	}
	return h.reply(c).Text(http.StatusOK, "ok")
}
