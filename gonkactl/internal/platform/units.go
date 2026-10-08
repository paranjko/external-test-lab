package platform

import (
	"fmt"
	"path/filepath"
	"strings"
)

const SupportedServiceABI = 1

// ServiceUnit is the immutable local execution description for a background
// worker. It deliberately contains no user environment or remote target.
type ServiceUnit struct {
	Name       string
	BinaryPath string
	Instance   string
	ServiceABI int
	Args       []string
}

func RenderUnit(unit ServiceUnit) (string, error) {
	if unit.Name == "" || unit.Instance == "" || unit.ServiceABI != SupportedServiceABI {
		return "", fmt.Errorf("unsupported service unit")
	}
	if !filepath.IsAbs(unit.BinaryPath) || !strings.HasPrefix(unit.BinaryPath, "/usr/local/lib/gonkactl/") {
		return "", fmt.Errorf("service binary must be a versioned installed path")
	}
	for _, arg := range unit.Args {
		if arg == "" || strings.ContainsAny(arg, "\r\n") {
			return "", fmt.Errorf("invalid service argument")
		}
	}
	return fmt.Sprintf("[Service]\nExecStart=%s internal %s\nEnvironment=GONKACTL_INSTANCE=%s\n", unit.BinaryPath, strings.Join(unit.Args, " "), unit.Instance), nil
}
