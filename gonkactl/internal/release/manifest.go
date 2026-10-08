package release

import "fmt"

type BuildManifest struct{ Profile, DefinitionSHA, SourceSHA, RuntimeID, ArtifactSHA string }

func (m BuildManifest) Validate() error {
	if m.Profile == "" || m.DefinitionSHA == "" || m.SourceSHA == "" || m.RuntimeID == "" || m.ArtifactSHA == "" {
		return fmt.Errorf("incomplete retained build manifest")
	}
	return nil
}
