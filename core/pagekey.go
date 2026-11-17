package gosite

import (
	"net/url"
	"strings"
)

// trackingParams only tell analytics where a visit came from. They never
// change what a page shows, so they stay out of the cache key: otherwise every
// ad click stores its own copy of the page. Names starting with utm_ are
// tracking parameters too (see isTrackingParam).
var trackingParams = map[string]bool{
	"gclid": true, "gbraid": true, "wbraid": true, "dclid": true,
	"fbclid": true, "msclkid": true, "yclid": true, "ttclid": true,
	"twclid": true, "li_fat_id": true, "igshid": true,
	"mc_cid": true, "mc_eid": true, "_ga": true, "_gl": true,
}

func isTrackingParam(name string) bool {
	n := strings.ToLower(name)
	return strings.HasPrefix(n, "utm_") || trackingParams[n]
}

// pageCacheKey names a URL in the page cache, and says whether a query is
// left in that name. One page gets one key: parameters are sorted, values are
// decoded and encoded again in one form (so "," and "%2C" match), and tracking
// parameters are dropped. The order of a repeated parameter's values is kept,
// because ?tag=a&tag=b may not mean the same as ?tag=b&tag=a.
//
// A URL without a query keeps the name it had before normalization existed,
// so those keys do not change.
func pageCacheKey(u *url.URL) (key string, hasQuery bool) {
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	if u.RawQuery == "" {
		return path, false
	}
	values, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		// A query that cannot be decoded is kept as received.
		return path + "?" + u.RawQuery, true
	}
	for name := range values {
		if isTrackingParam(name) {
			delete(values, name)
		}
	}
	if len(values) == 0 {
		return path, false
	}
	return path + "?" + values.Encode(), true
}
