// Package assets exposes the fixed, verified assets shipped with gonkactl.
package assets

import (
	_ "embed"
	"fmt"
)

//go:embed manifest.json
var manifestBytes []byte

//go:embed runtime.tar
var runtimeTar []byte

//go:embed profiles.tar
var profilesTar []byte

//go:embed runtime.schema.json
var runtimeSchema []byte

//go:embed recovery.schema.json
var recoverySchema []byte

// Schema returns a copy of a fixed embedded schema. Callers cannot mutate the
// process-wide embedded bytes.
func Schema(name string) ([]byte, error) {
	switch name {
	case "runtime.schema.json":
		return append([]byte(nil), runtimeSchema...), nil
	case "recovery.schema.json":
		return append([]byte(nil), recoverySchema...), nil
	default:
		return nil, fmt.Errorf("unknown embedded schema %q", name)
	}
}

func Manifest() ([]byte, error) {
	if err := validateBundles(manifestBytes, runtimeTar, profilesTar); err != nil {
		return nil, err
	}
	return append([]byte(nil), manifestBytes...), nil
}
