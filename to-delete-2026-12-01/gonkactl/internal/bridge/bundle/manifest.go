package bundle

import (
	"fmt"
	"regexp"
)

var hash = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Manifest struct {
	SourceSHA, LockSHA, ABISHA, BytecodeSHA, ProvenanceSHA string
	ChainID                                                int
}

func (m Manifest) Validate() error {
	if m.ChainID != 11155111 {
		return fmt.Errorf("unsupported bridge chain")
	}
	for _, v := range []string{m.SourceSHA, m.LockSHA, m.ABISHA, m.BytecodeSHA, m.ProvenanceSHA} {
		if !hash.MatchString(v) {
			return fmt.Errorf("unverified build manifest")
		}
	}
	return nil
}
