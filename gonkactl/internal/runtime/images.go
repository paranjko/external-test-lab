package runtime

import (
	"fmt"
	"strings"
)

func RequireDigest(image string) error {
	if !strings.Contains(image, "@sha256:") {
		return fmt.Errorf("image is not immutable: %q", image)
	}
	return nil
}
