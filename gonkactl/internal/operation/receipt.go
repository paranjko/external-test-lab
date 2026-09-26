package operation

import (
	"fmt"
	"path/filepath"
)

func AllowlistedReceipt(path, operationID string) error {
	if !filepath.IsAbs(path) || filepath.Base(path) == "." || operationID == "" {
		return fmt.Errorf("unsafe receipt path")
	}
	return nil
}
