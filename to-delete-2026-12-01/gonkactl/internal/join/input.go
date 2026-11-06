package join

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"path/filepath"
)

type PlanInput struct {
	Home, NodeName, PublicHost, Release, Composition, Output string
	Config                                                   json.RawMessage `json:"config"`
}

func (p PlanInput) Validate() error {
	if p.Release != "" || p.Composition != "" {
		return fmt.Errorf("release and composition are forbidden for ordinary join planning")
	}
	if p.Home != "" && !filepath.IsAbs(p.Home) {
		return fmt.Errorf("home must be absolute")
	}
	if len(p.Config) > 0 && string(p.Config) != "null" {
		var c map[string]json.RawMessage
		if json.Unmarshal(p.Config, &c) != nil {
			return fmt.Errorf("invalid config")
		}
		if c["release"] != nil || c["composition"] != nil {
			return fmt.Errorf("config release/composition forbidden")
		}
	}
	return nil
}
func (p PlanInput) Digest() string {
	b, _ := json.Marshal(struct{ Home, NodeName, PublicHost string }{p.Home, p.NodeName, p.PublicHost})
	return fmt.Sprintf("%x", sha256.Sum256(b))
}
