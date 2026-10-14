package platform

import "fmt"

// FirewallPlan describes only gonkactl-owned rules. Callers must snapshot and
// restore this owned set on probe failure; unrelated host rules are untouched.
type FirewallPlan struct {
	Role    Role
	Gateway bool
	Ports   []int
}

func NewFirewallPlan(role Role, gateway bool) (FirewallPlan, error) {
	if _, err := ResolveRole(role, false); err != nil && role != RoleNetworkGPU {
		return FirewallPlan{}, err
	}
	return FirewallPlan{Role: role, Gateway: gateway, Ports: ManagedIngress(role, gateway)}, nil
}

func (p FirewallPlan) Allows(port int) bool {
	for _, allowed := range p.Ports {
		if allowed == port {
			return true
		}
	}
	return false
}

func (p FirewallPlan) Validate() error {
	for _, forbidden := range []int{3000, 8000, 8081, 8082} {
		if p.Allows(forbidden) {
			return fmt.Errorf("forbidden management port %d", forbidden)
		}
	}
	return nil
}
