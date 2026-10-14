package release

import (
	"fmt"
	"regexp"
)

var digest = regexp.MustCompile(`^[0-9a-f]{64}$`)

func VerifySource(d Definition, checkoutSHA string) error {
	if !digest.MatchString(d.SHA256) || checkoutSHA == "" {
		return fmt.Errorf("unverified source")
	}
	return nil
}
