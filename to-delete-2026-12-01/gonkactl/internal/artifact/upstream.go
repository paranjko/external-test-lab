package artifact

import (
	"fmt"
	"strings"
)

func ImmutableImage(value string) error {
	if !strings.Contains(value, "@sha256:") {
		return fmt.Errorf("image must use immutable digest")
	}
	parts := strings.Split(value, "@sha256:")
	if len(parts) != 2 || parts[0] == "" || !sha256RE.MatchString(parts[1]) {
		return fmt.Errorf("invalid image digest")
	}
	return nil
}
func SelectPrimaryOrMirror(primary, mirror ReleaseMetadata, version, asset string) (ReleaseAsset, error) {
	a, err := ResolveRelease(primary, version, asset)
	if err == nil {
		return a, nil
	}
	if primary.Malformed {
		return ReleaseAsset{}, err
	}
	if primary.Available {
		return ReleaseAsset{}, err
	}
	return ResolveRelease(mirror, version, asset)
}
