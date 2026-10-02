package platform

import "fmt"

// SupportedHost is the deliberately narrow first-release host matrix.
func SupportedHost(ubuntuRelease, architecture string) bool {
	if architecture != "amd64" {
		return false
	}
	return ubuntuRelease == "22.04" || ubuntuRelease == "24.04" || ubuntuRelease == "26.04"
}

// RequireRoot uses the effective UID; it never infers identity from SUDO_USER.
func RequireRoot(euid int) error {
	if euid != 0 {
		return fmt.Errorf("host preparation requires root")
	}
	return nil
}
