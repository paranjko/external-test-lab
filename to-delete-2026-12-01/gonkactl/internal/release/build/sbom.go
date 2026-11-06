package build

import (
	"crypto/sha256"
	"fmt"
)

func SBOMDigest(source []byte) string { return fmt.Sprintf("%x", sha256.Sum256(source)) }
