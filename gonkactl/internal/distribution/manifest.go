package distribution

import (
	"fmt"
	"strings"
)

type Asset struct {
	Arch, URL, SHA256 string
	Size              int64
}

func (a Asset) Validate() error {
	if (a.Arch != "amd64" && a.Arch != "arm64") || !strings.HasPrefix(a.URL, "https://") || len(a.SHA256) != 64 || a.Size <= 0 {
		return fmt.Errorf("invalid installer asset")
	}
	return nil
}
