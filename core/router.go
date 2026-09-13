package gosite

import (
	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/cms"
)

// Router is what App.Routes receives: route registration, plus the core
// services a site's handlers are allowed to use.
type Router interface {
	GET(path string, h HandlerFunc, m ...Middleware)
	POST(path string, h HandlerFunc, m ...Middleware)
	PUT(path string, h HandlerFunc, m ...Middleware)
	PATCH(path string, h HandlerFunc, m ...Middleware)
	DELETE(path string, h HandlerFunc, m ...Middleware)

	// Group registers routes under a common prefix and middleware.
	Group(prefix string, m ...Middleware) Router

	// CMS is the Cockpit client. It is the only way site code reads content.
	CMS() *cms.Client

	// State is Redis storage for application data - rate limits, votes, last
	// known good values. Its keys live under "<project>:app:", which no purge
	// touches.
	State() *State
}

// routes is the registration surface shared by *echo.Echo and *echo.Group.
type routes interface {
	GET(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) echo.RouteInfo
	POST(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) echo.RouteInfo
	PUT(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) echo.RouteInfo
	PATCH(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) echo.RouteInfo
	DELETE(path string, h echo.HandlerFunc, m ...echo.MiddlewareFunc) echo.RouteInfo
	Group(prefix string, m ...echo.MiddlewareFunc) *echo.Group
}

type router struct {
	target routes
	state  *State
	cms    *cms.Client
}

func (r *router) GET(p string, h HandlerFunc, m ...Middleware)    { r.target.GET(p, h, m...) }
func (r *router) POST(p string, h HandlerFunc, m ...Middleware)   { r.target.POST(p, h, m...) }
func (r *router) PUT(p string, h HandlerFunc, m ...Middleware)    { r.target.PUT(p, h, m...) }
func (r *router) PATCH(p string, h HandlerFunc, m ...Middleware)  { r.target.PATCH(p, h, m...) }
func (r *router) DELETE(p string, h HandlerFunc, m ...Middleware) { r.target.DELETE(p, h, m...) }

func (r *router) Group(prefix string, m ...Middleware) Router {
	return &router{target: r.target.Group(prefix, m...), state: r.state, cms: r.cms}
}

func (r *router) CMS() *cms.Client { return r.cms }
func (r *router) State() *State    { return r.state }
