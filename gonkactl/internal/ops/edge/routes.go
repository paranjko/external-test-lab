package edge

import (
	"fmt"
	"net/url"
	"strings"
)

type Route struct{ Role, Path, Upstream string }

func ValidateRoutes(routes []Route) error {
	if len(routes) == 0 {
		return fmt.Errorf("routes required")
	}
	seen := map[string]bool{}
	for _, r := range routes {
		if r.Role != "public" && r.Role != "participant" {
			return fmt.Errorf("unknown edge role")
		}
		if !strings.HasPrefix(r.Path, "/") || seen[r.Path] {
			return fmt.Errorf("invalid route")
		}
		seen[r.Path] = true
		u, e := url.Parse(r.Upstream)
		if e != nil || u.Scheme != "http" || u.Host == "" || u.User != nil {
			return fmt.Errorf("unsafe upstream")
		}
	}
	return nil
}
