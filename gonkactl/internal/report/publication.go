package report

import (
	"fmt"
	"strings"
)

type Publication struct {
	Repository, Author, IssueState, Marker, BodyHash string
	Explicit                                         bool
}

func (p Publication) Validate() error {
	if !p.Explicit || p.Repository == "" || p.Author == "" || p.Marker == "" || p.BodyHash == "" {
		return fmt.Errorf("explicit publication authorization and draft binding required")
	}
	if strings.ToLower(p.IssueState) != "open" {
		return fmt.Errorf("target issue is not open")
	}
	return nil
}
func (p Publication) Verified(author, marker, bodyHash string) bool {
	return p.Author == author && p.Marker == marker && p.BodyHash == bodyHash
}
