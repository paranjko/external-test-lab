package release

import (
	"encoding/json"
	"fmt"
)

func RenderProfile(m BuildManifest) (json.RawMessage, error) {
	if m.Validate() != nil {
		return nil, m.Validate()
	}
	b, e := json.Marshal(struct{ Profile, Runtime, Artifact string }{m.Profile, m.RuntimeID, m.ArtifactSHA})
	if e != nil {
		return nil, fmt.Errorf("profile render: %w", e)
	}
	return b, nil
}
