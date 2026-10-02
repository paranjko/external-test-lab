package site

import "fmt"

type Manifest struct{ Revision, ContentSHA, TopologySHA, BootstrapSHA string }

func (m Manifest) Validate() error {
	if m.Revision == "" || len(m.ContentSHA) != 64 || len(m.TopologySHA) != 64 || len(m.BootstrapSHA) != 64 {
		return fmt.Errorf("invalid static site manifest")
	}
	return nil
}
