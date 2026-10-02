package report

import (
	"regexp"
	"strings"
)

var secret = regexp.MustCompile(`(?i)(token|secret|password|mnemonic)\s*[:=]\s*[^\s]+`)

func Sanitize(value string) string {
	return secret.ReplaceAllStringFunc(value, func(s string) string { return s[:strings.IndexAny(s, ":=")+1] + " [redacted]" })
}
