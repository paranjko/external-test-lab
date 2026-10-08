package platform

import "fmt"

type Role string

const (
	RoleAuto        Role = "auto"
	RoleNetworkOnly Role = "network-only"
	RoleNetworkGPU  Role = "network-gpu"
	RoleMLOnly      Role = "ml-only"
)

func ResolveRole(requested Role, gpuSupported bool) (Role, error) {
	switch requested {
	case "", RoleAuto:
		if gpuSupported {
			return RoleNetworkGPU, nil
		}
		return RoleNetworkOnly, nil
	case RoleNetworkOnly, RoleNetworkGPU, RoleMLOnly:
		return requested, nil
	default:
		return "", fmt.Errorf("unsupported host role %q", requested)
	}
}

// ManagedIngress is the finite, owned firewall allowlist. It contains no
// broad management ports and is applied independently from foreign chains.
func ManagedIngress(role Role, gateway bool) []int {
	ports := []int{5000}
	if role == RoleNetworkGPU || role == RoleNetworkOnly {
		ports = append(ports, 26660, 8088, 9101)
	}
	if gateway {
		ports = append(ports, 9099, 18080, 18085)
	}
	return ports
}
