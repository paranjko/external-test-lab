package release

import (
	"fmt"
	"sort"
)

type Definition struct{ Profile, SourceRef, Layer, SHA256 string }

func Select(defs []Definition, sourceRef, profile, layer string) (Definition, error) {
	matches := []Definition{}
	for _, d := range defs {
		if d.SourceRef == sourceRef && (profile == "" || d.Profile == profile) {
			matches = append(matches, d)
		}
	}
	if len(matches) != 1 {
		return Definition{}, fmt.Errorf("ambiguous or missing candidate definition")
	}
	d := matches[0]
	if layer != "" && layer != d.Layer {
		return Definition{}, fmt.Errorf("layer mismatch")
	}
	return d, nil
}
func SortedProfiles(defs []Definition) []string {
	o := []string{}
	for _, d := range defs {
		o = append(o, d.Profile)
	}
	sort.Strings(o)
	return o
}
