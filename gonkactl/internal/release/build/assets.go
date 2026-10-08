package build

import (
	"crypto/sha256"
	"fmt"
	"sort"
)

func AssetManifest(files map[string][]byte) map[string]string {
	o := map[string]string{}
	names := []string{}
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		o[n] = fmt.Sprintf("%x", sha256.Sum256(files[n]))
	}
	return o
}
