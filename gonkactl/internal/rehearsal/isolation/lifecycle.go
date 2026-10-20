package isolation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

var (
	ErrMutationUnknown = errors.New("runtime mutation outcome is unknown; reconciliation required")
	ErrResourceRemoved = errors.New("runtime resource was already removed")
	ErrAdoptionDenied  = errors.New("durable journal does not authorize resource adoption")
)

// AdoptionAuthorizer is implemented by the parent-owned journal/session layer.
// It must prove a durable intent and persisted resource evidence before the
// adapter will inspect and adopt an interrupted resource.
type AdoptionAuthorizer interface {
	AuthorizeAdoption(context.Context, PinnedResource) error
}

// NetworkAdoptionAuthorizer lets the parent journal authorize an interrupted
// network lifecycle independently from a container lifecycle.
type NetworkAdoptionAuthorizer interface {
	AuthorizeNetworkAdoption(context.Context, PinnedNetwork) error
}

type PinnedNetwork struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	RunID           string `json:"run_id"`
	OwnershipMarker string `json:"ownership_marker"`
	BindingDigest   string `json:"binding_digest"`
}

type PinnedResource struct {
	ID                   string            `json:"id"`
	Name                 string            `json:"name"`
	RunID                string            `json:"run_id"`
	OwnershipMarker      string            `json:"ownership_marker"`
	BindingDigest        string            `json:"binding_digest"`
	ForkKey              string            `json:"fork_key"`
	Image                string            `json:"image"`
	Ports                []Port            `json:"ports,omitempty"`
	Network              *PinnedNetwork    `json:"network,omitempty"`
	Entrypoint           []string          `json:"entrypoint,omitempty"`
	Argv                 []string          `json:"argv,omitempty"`
	Environment          map[string]string `json:"environment,omitempty"`
	DNSAliases           []string          `json:"dns_aliases,omitempty"`
	ForkTarget           string            `json:"fork_target,omitempty"`
	SelectedBinaryRole   BinaryRole        `json:"selected_binary_role,omitempty"`
	SelectedBinaryPath   string            `json:"selected_binary_path,omitempty"`
	SelectedBinaryDigest string            `json:"selected_binary_digest,omitempty"`
}

type RuntimeAdapter struct {
	mu                  sync.Mutex
	runner              ProcessRunner
	executable          string
	binding             contract.RunBinding
	bindingDigest       string
	authorizer          AdoptionAuthorizer
	owned               map[string]ownedState
	pins                map[string]PinnedResource
	ownedNetworks       map[string]ownedState
	unknownNetworkNames map[string]bool
}

type ownedState uint8

const (
	stateStopped ownedState = iota + 1
	stateRunning
	stateUnknown
	stateRemoved
)

func NewRuntimeAdapter(runner ProcessRunner, executable string, binding contract.RunBinding, authorizer AdoptionAuthorizer) (*RuntimeAdapter, error) {
	if runner == nil || executable == "" || contract.ValidateBinding(binding) != nil {
		return nil, ErrCommandPolicy
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return nil, err
	}
	binding = cloneRunBinding(binding)
	return &RuntimeAdapter{runner: runner, executable: executable, binding: binding, bindingDigest: digest, authorizer: authorizer, owned: map[string]ownedState{}, pins: map[string]PinnedResource{}, ownedNetworks: map[string]ownedState{}, unknownNetworkNames: map[string]bool{}}, nil
}

// CreateInternalNetwork creates one adapter-owned Docker internal network.
// It never attaches a container or publishes a host port.
func (a *RuntimeAdapter) CreateInternalNetwork(ctx context.Context) (PinnedNetwork, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	name := "gnk-" + a.binding.RunID
	if !safeName.MatchString(name) || a.unknownNetworkNames[name] {
		return PinnedNetwork{}, ErrMutationUnknown
	}
	command, err := networkCreateCommand(a.executable, name, a.binding, a.bindingDigest)
	if err != nil {
		return PinnedNetwork{}, err
	}
	stdout, _, code, runErr := a.runner.Run(ctx, command)
	id := strings.TrimSpace(string(stdout))
	if !safeRuntimeID(id) {
		a.unknownNetworkNames[name] = true
		return PinnedNetwork{}, fmt.Errorf("%w: network create outcome for %s cannot be identified", ErrMutationUnknown, name)
	}
	pin := PinnedNetwork{ID: id, Name: name, RunID: a.binding.RunID, OwnershipMarker: a.binding.OwnershipMarker, BindingDigest: a.bindingDigest}
	resource, inspectErr := a.inspectNetworkLocked(ctx, pin)
	if inspectErr != nil {
		a.unknownNetworkNames[name] = true
		return pin, fmt.Errorf("%w: created network inspection failed: %w", ErrMutationUnknown, inspectErr)
	}
	if len(resource.Consumers) != 0 {
		a.unknownNetworkNames[name] = true
		return pin, fmt.Errorf("%w: newly created network already has consumers", ErrMutationUnknown)
	}
	if runErr != nil || code != 0 {
		a.unknownNetworkNames[name] = true
		return pin, mutationFailure(OperationCreateNetwork, id, code, runErr)
	}
	a.ownedNetworks[id] = stateStopped
	return pin, nil
}

func (a *RuntimeAdapter) AdoptInternalNetwork(ctx context.Context, pin PinnedNetwork) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	gate, ok := a.authorizer.(NetworkAdoptionAuthorizer)
	if !ok || !validNetworkPin(pin, a.binding) || gate.AuthorizeNetworkAdoption(ctx, pin) != nil {
		return ErrAdoptionDenied
	}
	r, err := a.inspectNetworkLocked(ctx, pin)
	if err != nil {
		return err
	}
	if err := a.validateNetworkConsumersLocked(ctx, pin, r.Consumers); err != nil {
		return err
	}
	a.ownedNetworks[pin.ID] = stateStopped
	return nil
}

func (a *RuntimeAdapter) RemoveInternalNetwork(ctx context.Context, pin PinnedNetwork) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !validNetworkPin(pin, a.binding) || a.ownedNetworks[pin.ID] == 0 {
		return ErrForeignResource
	}
	if a.ownedNetworks[pin.ID] == stateRemoved {
		return nil
	}
	if a.ownedNetworks[pin.ID] == stateUnknown {
		return ErrMutationUnknown
	}
	n, err := a.inspectNetworkLocked(ctx, pin)
	if err != nil {
		return err
	}
	if err := a.validateNetworkConsumersLocked(ctx, pin, n.Consumers); err != nil {
		return err
	}
	if len(n.Consumers) != 0 {
		return fmt.Errorf("network has consumers: %w", ErrForeignResource)
	}
	cmd, err := networkActionCommand(a.executable, OperationRemoveNetwork, pin.ID)
	if err != nil {
		return err
	}
	_, _, code, err := a.runner.Run(ctx, cmd)
	if err != nil || code != 0 {
		a.ownedNetworks[pin.ID] = stateUnknown
		return mutationFailure(OperationRemoveNetwork, pin.ID, code, err)
	}
	a.ownedNetworks[pin.ID] = stateRemoved
	return nil
}

func (a *RuntimeAdapter) Create(ctx context.Context, spec ContainerSpec) (PinnedResource, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := spec.ValidateBinding(a.binding); err != nil {
		return PinnedResource{}, err
	}
	command, err := spec.createCommand(a.executable, a.binding)
	if err != nil {
		return PinnedResource{}, err
	}
	if err := a.verifyImage(ctx, spec.Image); err != nil {
		return PinnedResource{}, err
	}
	if spec.Network != nil {
		if a.ownedNetworks[spec.Network.ID] == 0 || a.ownedNetworks[spec.Network.ID] == stateUnknown || a.ownedNetworks[spec.Network.ID] == stateRemoved {
			return PinnedResource{}, ErrForeignResource
		}
		n, err := a.inspectNetworkLocked(ctx, *spec.Network)
		if err != nil {
			return PinnedResource{}, err
		}
		if err := a.validateNetworkConsumersLocked(ctx, *spec.Network, n.Consumers); err != nil {
			return PinnedResource{}, err
		}
	}
	stdout, _, code, runErr := a.runner.Run(ctx, command)
	id := strings.TrimSpace(string(stdout))
	if !safeRuntimeID(id) {
		if runErr != nil {
			return PinnedResource{}, fmt.Errorf("%w: create returned no verifiable resource ID: %w", ErrMutationUnknown, runErr)
		}
		return PinnedResource{}, ErrMutationUnknown
	}
	if _, exists := a.owned[id]; exists {
		return PinnedResource{}, fmt.Errorf("%w: runtime reused an already pinned resource ID", ErrForeignResource)
	}
	forkKey := selectedFork(spec)
	if forkKey == "" {
		return PinnedResource{}, ErrUnsafeSpec
	}
	pin := a.pin(id, forkKey, spec)
	// Provisional tracking permits endpoint ownership validation below; any
	// inconclusive inspect or create result immediately quarantines it.
	a.owned[id] = stateStopped
	a.pins[id] = pin
	resource, inspectErr := a.inspectLocked(ctx, pin)
	if inspectErr != nil {
		a.owned[id] = stateUnknown
		return pin, fmt.Errorf("%w: create returned %s but ownership inspection failed: %w", ErrMutationUnknown, id, inspectErr)
	}
	if pin.Network != nil {
		network, netErr := a.inspectNetworkLocked(ctx, *pin.Network)
		if netErr == nil {
			netErr = a.validateNetworkConsumersLocked(ctx, *pin.Network, network.Consumers)
		}
		if netErr != nil {
			a.owned[id] = stateUnknown
			return pin, fmt.Errorf("%w: post-create network endpoint verification failed: %w", ErrMutationUnknown, netErr)
		}
	}
	if resource.Running {
		a.owned[id] = stateUnknown
		return pin, fmt.Errorf("%w: create returned an unexpectedly running container", ErrMutationUnknown)
	}
	if runErr != nil || code != 0 {
		a.owned[id] = stateUnknown
		return pin, mutationFailure(OperationCreateContainer, id, code, runErr)
	}
	a.owned[id] = stateStopped
	return pin, nil
}

func (a *RuntimeAdapter) verifyImage(ctx context.Context, image string) error {
	command, err := ImageInspectCommand(a.executable, image)
	if err != nil {
		return err
	}
	stdout, _, code, err := a.runner.Run(ctx, command)
	if err != nil || code != 0 {
		return commandFailure(OperationInspectImage, code, err)
	}
	var docs []struct {
		ID          string   `json:"Id"`
		RepoDigests []string `json:"RepoDigests"`
	}
	if err := json.Unmarshal(stdout, &docs); err != nil || len(docs) != 1 {
		return fmt.Errorf("pinned image inspect response invalid")
	}
	if validLocalImageID(image) {
		if docs[0].ID == image {
			return nil
		}
		return fmt.Errorf("%w: local image content ID mismatch", ErrUnsafeSpec)
	}
	for _, reference := range docs[0].RepoDigests {
		if reference == image {
			return nil
		}
	}
	return fmt.Errorf("%w: pinned image is not preloaded under exact digest reference", ErrUnsafeSpec)
}
func commandFailure(operation Operation, code int, err error) error {
	if err != nil {
		return fmt.Errorf("%s failed (exit %d): %w", operation, code, err)
	}
	return fmt.Errorf("%s failed with exit %d", operation, code)
}
func mutationFailure(operation Operation, id string, code int, err error) error {
	if err != nil {
		return fmt.Errorf("%w: %s %s exit %d: %w", ErrMutationUnknown, operation, id, code, err)
	}
	return fmt.Errorf("%w: %s %s exit %d", ErrMutationUnknown, operation, id, code)
}

// Adopt requires parent-journal authorization in addition to the runtime's
// independently inspected run, owner, binding, network and mount identities.
func (a *RuntimeAdapter) Adopt(ctx context.Context, pin PinnedResource) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.validPin(pin) || a.authorizer == nil {
		return ErrAdoptionDenied
	}
	if err := a.authorizer.AuthorizeAdoption(ctx, pin); err != nil {
		return fmt.Errorf("%w: %v", ErrAdoptionDenied, err)
	}
	r, err := a.inspectLocked(ctx, pin)
	if err != nil {
		return err
	}
	if r.Running {
		a.owned[pin.ID] = stateRunning
	} else {
		a.owned[pin.ID] = stateStopped
	}
	a.pins[pin.ID] = pin
	return nil
}

func (a *RuntimeAdapter) Inspect(ctx context.Context, pin PinnedResource) (Resource, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.requireKnown(pin); err != nil {
		return Resource{}, err
	}
	r, err := a.inspectLocked(ctx, pin)
	if err == nil {
		if r.Running {
			a.owned[pin.ID] = stateRunning
		} else {
			a.owned[pin.ID] = stateStopped
		}
	}
	return r, err
}

func (a *RuntimeAdapter) Start(ctx context.Context, pin PinnedResource) error {
	return a.transition(ctx, pin, OperationStartContainer, stateRunning)
}
func (a *RuntimeAdapter) Stop(ctx context.Context, pin PinnedResource) error {
	return a.transition(ctx, pin, OperationStopContainer, stateStopped)
}

// KillRecovery performs the runner's hard-stop operation for an owned,
// recovery-role container only. The caller must already hold durable journal
// intent and a freshly validated barrier; this method does not validate barrier
// evidence or establish offline-store state. It never retries an uncertain
// kill outcome.
func (a *RuntimeAdapter) KillRecovery(ctx context.Context, pin PinnedResource) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.requireKnown(pin); err != nil {
		return err
	}
	if pin.SelectedBinaryRole != BinaryRecovery || pin.SelectedBinaryPath == "" || pin.SelectedBinaryDigest == "" {
		return ErrForeignResource
	}
	resource, err := a.inspectLocked(ctx, pin)
	if err != nil {
		return err
	}
	if !resource.Running || resource.StateStatus != "running" {
		if resource.Running {
			a.owned[pin.ID] = stateUnknown
			return fmt.Errorf("%w: recovery container state is not safely killable", ErrMutationUnknown)
		}
		a.owned[pin.ID] = stateStopped
		return fmt.Errorf("recovery container is not running; refusing hard stop")
	}
	a.owned[pin.ID] = stateRunning
	command, err := containerActionCommand(a.executable, OperationKillContainer, pin.ID)
	if err != nil {
		return err
	}
	_, _, code, runErr := a.runner.Run(ctx, command)
	if runErr != nil || code != 0 {
		a.owned[pin.ID] = stateUnknown
		return mutationFailure(OperationKillContainer, pin.ID, code, runErr)
	}
	verified, err := a.inspectLocked(ctx, pin)
	if err != nil {
		a.owned[pin.ID] = stateUnknown
		return fmt.Errorf("%w: post-kill inspection failed: %w", ErrMutationUnknown, err)
	}
	if verified.Running || verified.StateStatus != "exited" || !verified.ExitCodeKnown || verified.ExitCode != 137 {
		a.owned[pin.ID] = stateUnknown
		return fmt.Errorf("%w: post-kill state does not prove exited with signal status 137", ErrMutationUnknown)
	}
	a.owned[pin.ID] = stateStopped
	return nil
}

func (a *RuntimeAdapter) transition(ctx context.Context, pin PinnedResource, operation Operation, target ownedState) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.requireKnown(pin); err != nil {
		return err
	}
	if a.owned[pin.ID] == stateUnknown {
		return ErrMutationUnknown
	}
	r, err := a.inspectLocked(ctx, pin)
	if err != nil {
		return err
	}
	current := stateStopped
	if r.Running {
		current = stateRunning
	}
	a.owned[pin.ID] = current
	if current == target {
		return nil
	}
	command, err := containerActionCommand(a.executable, operation, pin.ID)
	if err != nil {
		return err
	}
	_, _, code, err := a.runner.Run(ctx, command)
	if err != nil || code != 0 {
		a.owned[pin.ID] = stateUnknown
		return mutationFailure(operation, pin.ID, code, err)
	}
	verified, err := a.inspectLocked(ctx, pin)
	if err != nil {
		a.owned[pin.ID] = stateUnknown
		return fmt.Errorf("%w: post-%s inspection failed: %w", ErrMutationUnknown, operation, err)
	}
	if (target == stateRunning) != verified.Running {
		a.owned[pin.ID] = stateUnknown
		return fmt.Errorf("%w: post-%s state contradicts requested transition", ErrMutationUnknown, operation)
	}
	a.owned[pin.ID] = target
	return nil
}

func (a *RuntimeAdapter) Remove(ctx context.Context, pin PinnedResource) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.validPin(pin) {
		return ErrForeignResource
	}
	state, ok := a.owned[pin.ID]
	if !ok {
		return ErrForeignResource
	}
	if state == stateRemoved {
		return nil
	}
	if state == stateUnknown {
		return ErrMutationUnknown
	}
	r, err := a.inspectLocked(ctx, pin)
	if err != nil {
		return err
	}
	if r.Running {
		return fmt.Errorf("refusing to remove running rehearsal resource %s", pin.ID)
	}
	if err := ValidateCleanup(a.binding, []string{pin.ID}, []Resource{r}); err != nil {
		return err
	}
	command, err := containerActionCommand(a.executable, OperationRemoveContainer, pin.ID)
	if err != nil {
		return err
	}
	_, _, code, err := a.runner.Run(ctx, command)
	if err != nil || code != 0 {
		a.owned[pin.ID] = stateUnknown
		return mutationFailure(OperationRemoveContainer, pin.ID, code, err)
	}
	a.owned[pin.ID] = stateRemoved
	return nil
}

// Cleanup processes only pins returned by Create or authorized through Adopt.
// A successful remove is remembered so repeating cleanup is a no-op.
func (a *RuntimeAdapter) Cleanup(ctx context.Context, pins []PinnedResource) error {
	if len(pins) == 0 {
		return ErrForeignResource
	}
	seen := map[string]bool{}
	for _, pin := range pins {
		if seen[pin.ID] {
			return ErrForeignResource
		}
		seen[pin.ID] = true
		a.mu.Lock()
		if !a.validPin(pin) {
			a.mu.Unlock()
			return ErrForeignResource
		}
		state, ok := a.owned[pin.ID]
		a.mu.Unlock()
		if !ok {
			return ErrForeignResource
		}
		if state == stateRemoved {
			continue
		}
		if err := a.Stop(ctx, pin); err != nil {
			return err
		}
		if err := a.Remove(ctx, pin); err != nil {
			return err
		}
	}
	return nil
}

func (a *RuntimeAdapter) requireKnown(pin PinnedResource) error {
	if !a.validPin(pin) {
		return ErrForeignResource
	}
	state, ok := a.owned[pin.ID]
	if !ok {
		return ErrForeignResource
	}
	if state == stateUnknown {
		return ErrMutationUnknown
	}
	if state == stateRemoved {
		return ErrResourceRemoved
	}
	return nil
}
func (a *RuntimeAdapter) validPin(pin PinnedResource) bool {
	if !safeRuntimeID(pin.ID) || !safeName.MatchString(pin.Name) || (pin.ForkKey != "fork-a" && pin.ForkKey != "fork-b") || !validImageDigest(pin.Image) || pin.RunID != a.binding.RunID || pin.OwnershipMarker != a.binding.OwnershipMarker || pin.BindingDigest != a.bindingDigest {
		return false
	}
	for _, p := range pin.Ports {
		if !validLoopbackPort(p.Host) || !validPort(p.Container) {
			return false
		}
	}
	if pin.Network != nil && !validNetworkPin(*pin.Network, a.binding) {
		return false
	}
	if pin.Network != nil && len(pin.Ports) != 0 {
		return false
	}
	if pin.ForkTarget != "" && pin.ForkTarget != "/root/.inference" {
		return false
	}
	if validateRecoveryFields(ContainerSpec{Entrypoint: pin.Entrypoint, Argv: pin.Argv, Environment: pin.Environment, DNSAliases: pin.DNSAliases, Network: pin.Network, ForkTarget: pin.ForkTarget, SelectedBinaryRole: pin.SelectedBinaryRole}, a.binding) != nil {
		return false
	}
	if pin.SelectedBinaryRole != "" {
		if pin.SelectedBinaryPath != a.binding.Paths[string(pin.SelectedBinaryRole)+"-binary"] || pin.SelectedBinaryDigest != a.binding.InputDigests[string(pin.SelectedBinaryRole)+"-binary"] {
			return false
		}
	} else if pin.SelectedBinaryDigest != "" || pin.SelectedBinaryPath != "" {
		return false
	}
	for _, alias := range pin.DNSAliases {
		if !safeDNSAlias.MatchString(alias) {
			return false
		}
	}
	if len(pin.DNSAliases) > 0 && pin.Network == nil {
		return false
	}
	return true
}
func (a *RuntimeAdapter) pin(id, forkKey string, spec ContainerSpec) PinnedResource {
	p := PinnedResource{ID: id, Name: spec.Name, RunID: a.binding.RunID, OwnershipMarker: a.binding.OwnershipMarker, BindingDigest: a.bindingDigest, ForkKey: forkKey, Image: spec.Image, Ports: append([]Port(nil), spec.Ports...), Entrypoint: append([]string(nil), spec.Entrypoint...), Argv: append([]string(nil), spec.Argv...), Environment: cloneStringMap(spec.Environment), DNSAliases: append([]string(nil), spec.DNSAliases...), ForkTarget: spec.ForkTarget, SelectedBinaryRole: spec.SelectedBinaryRole}
	if spec.SelectedBinaryRole != "" {
		p.SelectedBinaryPath = a.binding.Paths[string(spec.SelectedBinaryRole)+"-binary"]
		p.SelectedBinaryDigest = a.binding.InputDigests[string(spec.SelectedBinaryRole)+"-binary"]
	}
	if spec.Network != nil {
		n := *spec.Network
		p.Network = &n
	}
	return p
}

func selectedFork(spec ContainerSpec) string {
	for _, mount := range spec.Mounts {
		if mount.PathKey == "fork-a" || mount.PathKey == "fork-b" {
			return mount.PathKey
		}
	}
	return ""
}
func cloneRunBinding(b contract.RunBinding) contract.RunBinding {
	out := b
	out.InputDigests = map[string]string{}
	for k, v := range b.InputDigests {
		out.InputDigests[k] = v
	}
	out.RuntimeIdentities = map[string]string{}
	for k, v := range b.RuntimeIdentities {
		out.RuntimeIdentities[k] = v
	}
	out.Paths = map[string]string{}
	for k, v := range b.Paths {
		out.Paths[k] = v
	}
	if b.Heights.Consensus != nil {
		h := *b.Heights.Consensus
		out.Heights.Consensus = &h
	}
	return out
}

type inspectDocument struct {
	ID     string `json:"Id"`
	Config struct {
		Labels     map[string]string `json:"Labels"`
		Image      string            `json:"Image"`
		Entrypoint []string          `json:"Entrypoint"`
		Cmd        []string          `json:"Cmd"`
		Env        []string          `json:"Env"`
	} `json:"Config"`
	HostConfig struct {
		NetworkMode  string                         `json:"NetworkMode"`
		PidMode      string                         `json:"PidMode"`
		Privileged   bool                           `json:"Privileged"`
		IpcMode      string                         `json:"IpcMode"`
		UTSMode      string                         `json:"UTSMode"`
		UsernsMode   string                         `json:"UsernsMode"`
		CgroupnsMode string                         `json:"CgroupnsMode"`
		CapAdd       []string                       `json:"CapAdd"`
		Devices      []any                          `json:"Devices"`
		SecurityOpt  []string                       `json:"SecurityOpt"`
		PortBindings map[string][]dockerPortBinding `json:"PortBindings"`
	} `json:"HostConfig"`
	State struct {
		Running    bool   `json:"Running"`
		Status     string `json:"Status"`
		ExitCode   *int   `json:"ExitCode"`
		Paused     bool   `json:"Paused"`
		Restarting bool   `json:"Restarting"`
	} `json:"State"`
	Mounts          []dockerMount `json:"Mounts"`
	NetworkSettings struct {
		Networks map[string]struct {
			NetworkID string   `json:"NetworkID"`
			Aliases   []string `json:"Aliases"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}
type networkInspectDocument struct {
	ID         string                     `json:"Id"`
	Name       string                     `json:"Name"`
	Driver     string                     `json:"Driver"`
	Internal   bool                       `json:"Internal"`
	Labels     map[string]string          `json:"Labels"`
	Containers map[string]json.RawMessage `json:"Containers"`
}
type dockerPortBinding struct {
	HostIP   string `json:"HostIp"`
	HostPort string `json:"HostPort"`
}
type dockerMount struct {
	Type        string `json:"Type"`
	Source      string `json:"Source"`
	Destination string `json:"Destination"`
	Mode        string `json:"Mode"`
	RW          bool   `json:"RW"`
}

func (a *RuntimeAdapter) inspectLocked(ctx context.Context, pin PinnedResource) (Resource, error) {
	if !validRolePaths(a.binding.Paths) {
		return Resource{}, ErrUnsafeSpec
	}
	if pin.Entrypoint != nil {
		if err := boundRecoveryFilesMatch(a.binding, pin.SelectedBinaryRole); err != nil {
			return Resource{}, err
		}
	}
	if !a.validPin(pin) {
		return Resource{}, ErrForeignResource
	}
	command, err := ResourcesInspectCommand(a.executable, []string{pin.ID})
	if err != nil {
		return Resource{}, err
	}
	stdout, _, code, err := a.runner.Run(ctx, command)
	if err != nil || code != 0 {
		return Resource{}, commandFailure(OperationInspectResources, code, err)
	}
	var documents []inspectDocument
	if err := json.Unmarshal(stdout, &documents); err != nil || len(documents) != 1 {
		return Resource{}, fmt.Errorf("invalid inspect response for %s", pin.ID)
	}
	d := documents[0]
	if d.ID != pin.ID || d.Config.Labels["gonka.rehearsal.run"] != a.binding.RunID || d.Config.Labels["gonka.rehearsal.owner"] != a.binding.OwnershipMarker || d.Config.Labels["gonka.rehearsal.binding"] != a.bindingDigest {
		return Resource{}, ErrForeignResource
	}
	expectedNetwork := "none"
	if pin.Network != nil {
		expectedNetwork = pin.Network.Name
	}
	if d.Config.Image != pin.Image || d.HostConfig.NetworkMode != expectedNetwork || d.HostConfig.PidMode != "" || d.HostConfig.IpcMode != "" || d.HostConfig.UTSMode != "" || d.HostConfig.UsernsMode == "host" || d.HostConfig.CgroupnsMode == "host" || d.HostConfig.Privileged || len(d.HostConfig.CapAdd) != 0 || len(d.HostConfig.Devices) != 0 || len(d.HostConfig.SecurityOpt) != 0 {
		return Resource{}, ErrUnsafeSpec
	}
	if pin.Network == nil && len(d.NetworkSettings.Networks) != 0 {
		return Resource{}, ErrUnsafeSpec
	}
	if pin.Network != nil {
		if len(d.NetworkSettings.Networks) != 1 {
			return Resource{}, ErrUnsafeSpec
		}
		endpoint, ok := d.NetworkSettings.Networks[pin.Network.Name]
		if !ok || endpoint.NetworkID != pin.Network.ID || !dnsAliasesMatch(endpoint.Aliases, pin.Name, pin.DNSAliases) {
			return Resource{}, ErrUnsafeSpec
		}
	}
	if !a.mountsMatch(d.Mounts, pin.ForkKey, pin.ForkTarget, pin.SelectedBinaryRole) || !portsMatch(d.HostConfig.PortBindings, pin.Ports) || !containerCommandMatches(d, pin) {
		return Resource{}, ErrUnsafeSpec
	}
	if d.State.Paused || d.State.Restarting || (d.State.Running && d.State.Status != "running") {
		return Resource{}, ErrMutationUnknown
	}
	resource := Resource{ID: d.ID, Labels: d.Config.Labels, Running: d.State.Running, StateStatus: d.State.Status}
	if d.State.ExitCode != nil {
		resource.ExitCode = *d.State.ExitCode
		resource.ExitCodeKnown = true
	}
	return resource, nil
}

func portsMatch(got map[string][]dockerPortBinding, expected []Port) bool {
	if len(got) != len(expected) {
		return false
	}
	for _, p := range expected {
		host, hostPort, err := net.SplitHostPort(p.Host)
		if err != nil {
			return false
		}
		bindings, ok := got[p.Container+"/tcp"]
		if !ok || len(bindings) != 1 || bindings[0].HostIP != host || bindings[0].HostPort != hostPort {
			return false
		}
	}
	return true
}

func (a *RuntimeAdapter) mountsMatch(got []dockerMount, forkKey, forkTarget string, binaryRole BinaryRole) bool {
	expected := map[string]bool{}
	for _, key := range []string{"source", "control", "evidence", "fork-a", "fork-b"} {
		if key != "source" && key != "control" && key != "evidence" {
			continue
		}
		expected[bindingPath(a.binding, key)+"\x00"+expectedTarget(key)+"\x00ro"] = true
	}
	// A given fork container mounts exactly one writable fork path. Distinguish
	// its role from the container ID naming convention established at creation.
	if forkTarget == "" {
		forkTarget = "/data"
	}
	expected[bindingPath(a.binding, forkKey)+"\x00"+forkTarget+"\x00rw"] = true
	if len(a.binding.Paths["recovery-binary"]) > 0 {
		binaryKey := selectedBinaryPathKey(binaryRole)
		if binaryKey == "" {
			return false
		}
		expected[a.binding.Paths[binaryKey]+"\x00/root/gnklab0002/selected/inferenced\x00ro"] = true
	}
	if len(got) != len(expected) {
		return false
	}
	for _, m := range got {
		mode := m.Mode
		if mode == "" {
			if m.RW {
				mode = "rw"
			} else {
				mode = "ro"
			}
		}
		key := m.Source + "\x00" + m.Destination + "\x00" + mode
		if m.Type != "bind" || !expected[key] {
			return false
		}
		delete(expected, key)
	}
	return len(expected) == 0
}

func containerCommandMatches(d inspectDocument, p PinnedResource) bool {
	entrypoint := []string(nil)
	command := append([]string(nil), p.Argv...)
	if len(p.Entrypoint) > 0 {
		entrypoint = []string{p.Entrypoint[0]}
		command = append(append([]string(nil), p.Entrypoint[1:]...), command...)
	}
	if !equalStrings(d.Config.Entrypoint, entrypoint) || !equalStrings(d.Config.Cmd, command) {
		return false
	}
	actual := map[string]string{}
	for _, item := range d.Config.Env {
		k, v, ok := strings.Cut(item, "=")
		if !ok || k == "" {
			return false
		}
		if _, dup := actual[k]; dup {
			return false
		}
		actual[k] = v
	}
	if len(actual) != len(p.Environment) {
		return false
	}
	for k, v := range p.Environment {
		if actual[k] != v {
			return false
		}
	}
	return true
}
func dnsAliasesMatch(actual []string, name string, expected []string) bool {
	want := map[string]bool{name: true}
	for _, a := range expected {
		want[a] = true
	}
	got := map[string]bool{}
	for _, a := range actual {
		if got[a] {
			return false
		}
		got[a] = true
	}
	if len(got) != len(want) {
		return false
	}
	for a := range want {
		if !got[a] {
			return false
		}
	}
	return true
}
func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func (a *RuntimeAdapter) inspectNetworkLocked(ctx context.Context, pin PinnedNetwork) (Resource, error) {
	if !validNetworkPin(pin, a.binding) {
		return Resource{}, ErrForeignResource
	}
	cmd, err := NetworkInspectCommand(a.executable, pin.ID)
	if err != nil {
		return Resource{}, err
	}
	out, _, code, err := a.runner.Run(ctx, cmd)
	if err != nil || code != 0 {
		return Resource{}, commandFailure(OperationInspectNetwork, code, err)
	}
	var docs []networkInspectDocument
	if err := json.Unmarshal(out, &docs); err != nil || len(docs) != 1 {
		return Resource{}, errors.New("invalid network inspect response")
	}
	d := docs[0]
	if d.ID != pin.ID || d.Name != pin.Name || d.Driver != "bridge" || !d.Internal || d.Labels["gonka.rehearsal.run"] != a.binding.RunID || d.Labels["gonka.rehearsal.owner"] != a.binding.OwnershipMarker || d.Labels["gonka.rehearsal.binding"] != a.bindingDigest {
		return Resource{}, ErrForeignResource
	}
	consumers := make([]string, 0, len(d.Containers))
	for id := range d.Containers {
		consumers = append(consumers, id)
	}
	sort.Strings(consumers)
	return Resource{ID: d.ID, Labels: d.Labels, Consumers: consumers}, nil
}

func validNetworkPin(pin PinnedNetwork, b contract.RunBinding) bool {
	digest, err := contract.Digest(b)
	return err == nil && safeRuntimeID(pin.ID) && safeName.MatchString(pin.Name) && pin.Name == "gnk-"+b.RunID && pin.RunID == b.RunID && pin.OwnershipMarker == b.OwnershipMarker && pin.BindingDigest == digest
}

func (a *RuntimeAdapter) validateNetworkConsumersLocked(ctx context.Context, network PinnedNetwork, ids []string) error {
	for _, id := range ids {
		pin, ok := a.pins[id]
		if !ok || pin.Network == nil || pin.Network.ID != network.ID || !a.validPin(pin) || a.owned[id] == stateUnknown || a.owned[id] == stateRemoved {
			return fmt.Errorf("network has an unowned endpoint: %w", ErrForeignResource)
		}
		if _, err := a.inspectLocked(ctx, pin); err != nil {
			return err
		}
	}
	return nil
}
