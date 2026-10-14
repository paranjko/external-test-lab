package artifact

import (
	"fmt"
	"regexp"
	"strings"
)

var sha256RE = regexp.MustCompile(`^[0-9a-f]{64}$`)
var commitRE = regexp.MustCompile(`^[0-9a-f]{40}$`)

type ReleaseAsset struct{ Name, URL, SHA256 string }
type ReleaseMetadata struct {
	Tag, Commit string
	Assets      []ReleaseAsset
	Available   bool
	Malformed   bool
}

func ResolveRelease(metadata ReleaseMetadata, version, asset string) (ReleaseAsset, error) {
	if metadata.Malformed {
		return ReleaseAsset{}, fmt.Errorf("malformed primary metadata")
	}
	if !metadata.Available {
		return ReleaseAsset{}, fmt.Errorf("primary metadata unavailable")
	}
	if metadata.Tag != "release/v"+version || !commitRE.MatchString(metadata.Commit) {
		return ReleaseAsset{}, fmt.Errorf("release tag or commit mismatch")
	}
	var found []ReleaseAsset
	for _, a := range metadata.Assets {
		if a.Name == asset {
			found = append(found, a)
		}
	}
	if len(found) != 1 || !strings.HasPrefix(found[0].URL, "https://") || !sha256RE.MatchString(found[0].SHA256) {
		return ReleaseAsset{}, fmt.Errorf("required asset unavailable or invalid")
	}
	return found[0], nil
}
