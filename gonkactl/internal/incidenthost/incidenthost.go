// Package incidenthost implements the Linux host operations for the
// GNK-LAB-2026-0002 recovery. It is deliberately specific to this incident.
package incidenthost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

// Target contains the inspected original-container identity supplied by the
// caller's fixed incident inventory. Consumers is a pipe-separated list of
// full Docker container IDs that are permitted to mount the chain data.
type Target struct {
	Original   string
	Image      string
	Entrypoint string
	Consumers  string
}

// Result contains only the runtime facts needed by the caller and evidence
// receipt. Container configuration, including environment values, is omitted.
type Result struct {
	Node     string          `json:"node"`
	Phase    string          `json:"phase"`
	Original ContainerState  `json:"original"`
	Recovery *ContainerState `json:"recovery,omitempty"`
	Barrier  json.RawMessage `json:"barrier,omitempty"`
	Logs     string          `json:"logs,omitempty"`
}

// ContainerState intentionally exposes no Config, HostConfig, or environment.
type ContainerState struct {
	ID       string `json:"id"`
	Image    string `json:"image"`
	Status   string `json:"status"`
	Running  bool   `json:"running"`
	PID      int    `json:"pid"`
	ExitCode int    `json:"exit_code"`
}

var (
	nodePattern = regexp.MustCompile(`^node[0-9]+$`)
	idPattern   = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

const (
	recoveryImageID = "sha256:29a529c84ccf6a84fc9d009290b2dbd622d4cc8079e20d87a097e9d4c0e70884"
	recoveryName    = "gnklab0002-%s-bcb9de867"
	recoveryRoot    = "/srv/dai/recovery/gnklab0002-bcb9de867"
	dataMount       = "/srv/dai/data/inference"
	dataRoot        = "/srv/dai/data/inference/data"
	originalBinary  = "/srv/dai/data/inference/cosmovisor/current/bin/inferenced"
	identityDir     = "/srv/dai/identity"
	genesisFile     = "/srv/dai/shared/genesis.json"
	incidentLabel   = "GNK-LAB-2026-0002"
	barrierFile     = "barrier-handshake-replay-814730.json"
	chainID         = "gonka-devnet-community"
	barrierAppHash  = "ed4e4a7e57c0e336d1b749a21c367f9a2775d42f9aaf151824fc7032f3f4f4f4"
	barrierBlockID  = "52B5413D4650C80126E6222CA4AA6868CC6FBA278E97D1188D9D5EEE3A2A0EFC/1:31254953C98EF1F55862FB23D5AC21E94E036C397AC1F11BBFE6724FBA4CFB98"
	originalBinHash = "2f6a31c3ecda063a84fcfd80782fe5b00908f9b678da9204d6c7acba602260de"
	preABCIHash     = "O/yQOYaGY8fafmHchcTvo3lz6194TpbWzGSHYbNc3vk="
)

// Run executes one incident recovery phase on a Linux host. The target must
// come from the caller's inspected, fixed incident inventory.
func Run(ctx context.Context, node, phase string, target Target) (any, error) {
	if err := validate(node, phase, target); err != nil {
		return nil, err
	}
	return runLinux(ctx, node, phase, target)
}

func validate(node, phase string, target Target) error {
	if !nodePattern.MatchString(node) {
		return errors.New("incidenthost: invalid node name")
	}
	switch phase {
	case "status", "repair", "launch", "halt", "resume":
	default:
		return fmt.Errorf("incidenthost: unsupported phase %q", phase)
	}
	if !idPattern.MatchString(target.Original) {
		return errors.New("incidenthost: invalid pinned original container ID")
	}
	if len(target.Image) != 71 || target.Image[:7] != "sha256:" || !idPattern.MatchString(target.Image[7:]) {
		return errors.New("incidenthost: invalid pinned original image ID")
	}
	var entrypoint []string
	if err := json.Unmarshal([]byte(target.Entrypoint), &entrypoint); err != nil {
		return errors.New("incidenthost: invalid pinned entrypoint JSON")
	}
	if len(target.Consumers) == 0 {
		return errors.New("incidenthost: empty allowed-consumer inventory")
	}
	seen := map[string]bool{}
	for _, id := range regexp.MustCompile(`\|`).Split(target.Consumers, -1) {
		if !idPattern.MatchString(id) || seen[id] {
			return errors.New("incidenthost: invalid allowed-consumer inventory")
		}
		seen[id] = true
	}
	return nil
}
