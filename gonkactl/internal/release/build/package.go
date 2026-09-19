package build

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"path/filepath"
)

func Package(ctx context.Context, workspace string, definition json.RawMessage) (json.RawMessage, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if !filepath.IsAbs(workspace) || !json.Valid(definition) {
		return nil, fmt.Errorf("invalid package inputs")
	}
	h := sha256.Sum256(definition)
	return json.RawMessage(`{"workspace":"` + workspace + `","definition_sha256":"` + fmt.Sprintf("%x", h) + `"}`), nil
}
