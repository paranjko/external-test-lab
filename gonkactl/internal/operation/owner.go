package operation

import (
	"fmt"
	"regexp"
	"time"
)

var hashRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

type OwnerBundle struct {
	Kind, TargetRole, TargetInstanceID, ChainID, GenesisRawSHA256, InputsSHA256 string
	ExpiresAt                                                                   *time.Time
}

func (b OwnerBundle) Validate(now time.Time) error {
	if b.Kind == "" || b.TargetRole == "" || b.ChainID == "" || !hashRE.MatchString(b.GenesisRawSHA256) || !hashRE.MatchString(b.InputsSHA256) {
		return fmt.Errorf("invalid owner bundle")
	}
	if b.ExpiresAt != nil && !b.ExpiresAt.After(now) {
		return fmt.Errorf("expired owner bundle")
	}
	return nil
}
