package github

import (
	"fmt"
	"os"
	"strings"
)

func TokenFromPrivateFile(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("token file required")
	}
	info, e := os.Stat(path)
	if e != nil || info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("unsafe token file")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return "", e
	}
	token := strings.TrimSpace(string(b))
	if token == "" {
		return "", fmt.Errorf("empty token")
	}
	return token, nil
}
