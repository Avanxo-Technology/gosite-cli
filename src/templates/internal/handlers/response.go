package handlers

import (
	"fmt"
	"html"
	"net/http"
	"strings"

	"github.com/labstack/echo/v5"
)

// Response is a thin layer over Echo's own response helpers
// (https://echo.labstack.com/guide/response/): Context.HTMLBlob, Context.String
// and Context.JSON already know how to set content types and write the body,
// so nothing here re-implements them.
//
// What it does add is the bookkeeping this app would otherwise repeat in every
// handler: the cache header, and logging an error while replying with a
// message that is safe to show a client.
//
// Usage: return h.reply(c).Page(html, cached)
type Response struct {
	h *Handlers
	c *echo.Context
}

func (h *Handlers) reply(c *echo.Context) Response {
	return Response{h: h, c: c}
}

// Page sends a rendered HTML page and records whether it came from the cache.
// The X-Cache header makes the cache observable in devtools without putting
// anything in the markup.
func (r Response) Page(html []byte, cached bool) error {
	status := "MISS"
	if cached {
		status = "HIT"
	}
	r.c.Response().Header().Set("X-Cache", status)
	return r.c.HTMLBlob(http.StatusOK, html)
}

// Text sends a plain-text response, for endpoints with nothing to render.
func (r Response) Text(status int, message string) error {
	return r.c.String(status, message)
}

// JSON sends a JSON response, for when this app grows an API route.
func (r Response) JSON(status int, body any) error {
	return r.c.JSON(status, body)
}

// Fail logs the real error and returns a generic message to the client, so
// internal details never leak and no handler has to remember to do both.
// Echo's error handler turns the returned HTTPError into the response.
// For browser requests, a minimal HTML page is served instead of JSON.
func (r Response) Fail(status int, message string, err error) error {
	if err != nil {
		r.h.Log.Error(message, "err", err, "path", r.c.Request().URL.Path)
	}
	if strings.Contains(r.c.Request().Header.Get("Accept"), "text/html") {
		return r.c.HTML(status, errorPage(status, message, err))
	}
	return echo.NewHTTPError(status, message)
}

// errorPage returns a minimal, self-contained HTML error page. In dev mode
// the real error is shown so the developer can diagnose without checking logs.
func errorPage(status int, message string, err error) string {
	var detail string
	if err != nil {
		detail = fmt.Sprintf("<p class=\"err\">%s</p>", html.EscapeString(err.Error()))
	}
	return fmt.Sprintf(`<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>%d</title>
<style>body{font:16px/1.5 system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#0f172a;color:#e2e8f0}main{text-align:center;max-width:480px;padding:2rem}h1{font-size:4rem;margin:0;opacity:.4}p{margin:.5rem 0}h2{margin:0;font-size:1.25rem}h2+p{color:#94a3b8}.err{font:12px/1.4 ui-monospace,monospace;color:#f87171;margin-top:1.5rem;padding:1rem;background:#1e293b;border-radius:8px;text-align:left;word-break:break-all}</style></head>
<body><main><h1>%d</h1><h2>%s</h2><p>Intenta de nuevo en unos segundos.</p>%s</main></body></html>`,
		status, status, html.EscapeString(message), detail)
}
