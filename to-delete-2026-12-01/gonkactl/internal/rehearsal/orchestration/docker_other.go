//go:build !linux

package orchestration

import (
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/driver"
)

type PlanBuild func(contract.RunBinding) (driver.Plan, error)

func DockerBuild(PlanBuild, string, driver.EvidenceHooks) Build {
	return func(contract.RunBinding) (Runtime, error) { return nil, ErrUnavailable }
}
