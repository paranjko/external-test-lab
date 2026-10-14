package composition

import "fmt"

func Verify(d Descriptor) error {
	if d.Core == "" || d.DevShard == "" || d.Governance == "" || d.SHA256 == "" {
		return fmt.Errorf("incomplete composition descriptor")
	}
	if !d.SelfContained {
		return fmt.Errorf("workspace required for non-self-contained descriptor")
	}
	return nil
}
