package isolation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const fakeContainerID = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const fakeNetworkID = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

type fakeRuntimeContainer struct {
	ID                 string
	Labels             map[string]string
	ForkKey            string
	Image              string
	Ports              []Port
	Network            *PinnedNetwork
	Name               string
	Entrypoint         []string
	Cmd                []string
	Environment        map[string]string
	Aliases            []string
	ForkTarget         string
	Mounts             []fakeMount
	SelectedBinaryRole string
	Running            bool
	StateStatus        string
	ExitCode           int
	ExitCodeKnown      bool
}
type fakeMount struct{ Source, Target, Mode string }
type fakeRuntimeNetwork struct {
	ID, Name  string
	Labels    map[string]string
	Internal  bool
	Consumers map[string]bool
}
type fakePortBinding struct {
	HostIP   string `json:"HostIp"`
	HostPort string `json:"HostPort"`
}
type fakeRuntimeProcess struct {
	mu                sync.Mutex
	child             *NativeRunner
	executable        string
	binding           contract.RunBinding
	image             string
	imageInspectID    string
	imageRepoDigests  []string
	containers        map[string]fakeRuntimeContainer
	createdContainers int
	networks          map[string]fakeRuntimeNetwork
	operations        []Operation
	commands          []Command
	failOperation     Operation
	badKillExit       bool
	omitKillExitCode  bool
	onOperation       func(Operation)
}

func newFakeRuntimeProcess(t *testing.T, b contract.RunBinding) *fakeRuntimeProcess {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	child, err := NewNativeRunner(ProcessPolicy{Executables: []string{exe}, Operations: []Operation{operationTestHelper}, Timeout: 4 * time.Second, MaxOutputBytes: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	return &fakeRuntimeProcess{child: child, executable: exe, binding: cloneRunBinding(b), containers: map[string]fakeRuntimeContainer{}, networks: map[string]fakeRuntimeNetwork{}}
}
func (f *fakeRuntimeProcess) Run(ctx context.Context, command Command) ([]byte, []byte, int, error) {
	f.mu.Lock()
	op := command.Operation()
	args := command.Args()
	f.operations = append(f.operations, op)
	f.commands = append(f.commands, command)
	stdout := ""
	helperMode := "reply"
	exitCode := 0
	switch op {
	case OperationInspectImage:
		imageID := f.imageInspectID
		if imageID == "" {
			imageID = args[2]
		}
		repos := f.imageRepoDigests
		if repos == nil {
			repos = []string{args[2]}
		}
		encoded, _ := json.Marshal([]any{map[string]any{"Id": imageID, "RepoDigests": repos}})
		stdout = string(encoded)
		f.image = args[2]
		if f.failOperation == op {
			helperMode = "reply-exit"
			exitCode = 7
		}
	case OperationCreateContainer:
		containerID := fakeContainerID
		if f.createdContainers > 0 {
			containerID = fmt.Sprintf("%064x", f.createdContainers)
		}
		f.createdContainers++
		fork := "fork-a"
		for _, arg := range args {
			if strings.Contains(arg, "src="+f.binding.Paths["fork-b"]+",") {
				fork = "fork-b"
			}
		}
		labels := map[string]string{"gonka.rehearsal.run": f.binding.RunID, "gonka.rehearsal.owner": f.binding.OwnershipMarker}
		labels["gonka.rehearsal.binding"], _ = contract.Digest(f.binding)
		container := fakeRuntimeContainer{ID: containerID, Name: args[2], Labels: labels, ForkKey: fork, Image: f.image, Environment: map[string]string{}}
		imageAt := -1
		for i, arg := range args {
			if validImageDigest(arg) {
				imageAt = i
				break
			}
		}
		if imageAt >= 0 {
			container.Cmd = append([]string(nil), args[imageAt+1:]...)
			for i := 0; i < imageAt; i++ {
				if args[i] == "--entrypoint" && i+1 < imageAt {
					container.Entrypoint = []string{args[i+1]}
				}
				if args[i] == "--env" && i+1 < imageAt {
					kv := strings.SplitN(args[i+1], "=", 2)
					if len(kv) == 2 {
						container.Environment[kv[0]] = kv[1]
						if kv[0] == "GNK_LAB_SELECTED_BINARY_ROLE" {
							container.SelectedBinaryRole = kv[1]
						}
					}
				}
				if args[i] == "--network-alias" && i+1 < imageAt {
					container.Aliases = append(container.Aliases, args[i+1])
				}
				if args[i] == "--mount" && i+1 < imageAt {
					container.Mounts = append(container.Mounts, parseFakeMount(args[i+1]))
				}
				if args[i] == "--publish" && i+1 < imageAt {
					value := args[i+1]
					sep := strings.LastIndex(value, ":")
					if sep > 0 {
						host := value[:sep]
						containerPort := value[sep+1:]
						last := strings.LastIndex(host, ":")
						if last > 0 {
							container.Ports = append(container.Ports, Port{Host: host[:last] + ":" + host[last+1:], Container: containerPort})
						}
					}
				}
			}
		}
		container.ForkTarget = "/data"
		for _, m := range container.Mounts {
			if m.Source == f.binding.Paths[fork] {
				container.ForkTarget = m.Target
			}
		}
		if len(args) > 4 && args[4] != "none" {
			for _, n := range f.networks {
				if n.Name == args[4] {
					pin := PinnedNetwork{ID: n.ID, Name: n.Name, RunID: f.binding.RunID, OwnershipMarker: f.binding.OwnershipMarker}
					pin.BindingDigest, _ = contract.Digest(f.binding)
					container.Network = &pin
					container.Aliases = append(container.Aliases, container.Name)
					n.Consumers[containerID] = true
					f.networks[n.ID] = n
					container.Ports = nil
				}
			}
		}
		f.containers[containerID] = container
		stdout = containerID
		if f.failOperation == op {
			helperMode = "reply-exit"
			exitCode = 7
		}
	case OperationInspectResources:
		id := args[len(args)-1]
		container, ok := f.containers[id]
		if !ok {
			helperMode = "reply-exit"
			exitCode = 1
			stdout = "no such object"
			break
		}
		stdout = f.inspectJSON(container)
	case OperationCreateNetwork:
		labels := map[string]string{}
		for i := 5; i < len(args)-1; i += 2 {
			kv := strings.SplitN(args[i+1], "=", 2)
			if len(kv) == 2 {
				labels[kv[0]] = kv[1]
			}
		}
		name := args[len(args)-1]
		f.networks[fakeNetworkID] = fakeRuntimeNetwork{ID: fakeNetworkID, Name: name, Labels: labels, Internal: true, Consumers: map[string]bool{}}
		stdout = fakeNetworkID
		if f.failOperation == op {
			helperMode = "reply-exit"
			exitCode = 7
		}
	case OperationInspectNetwork:
		n, ok := f.networks[args[2]]
		if !ok {
			helperMode = "reply-exit"
			exitCode = 1
			break
		}
		consumers := map[string]any{}
		for id := range n.Consumers {
			consumers[id] = map[string]string{}
		}
		data := []any{map[string]any{"Id": n.ID, "Name": n.Name, "Driver": "bridge", "Internal": n.Internal, "Labels": n.Labels, "Containers": consumers}}
		encoded, _ := json.Marshal(data)
		stdout = string(encoded)
	case OperationRemoveNetwork:
		n, ok := f.networks[args[2]]
		if !ok || len(n.Consumers) > 0 {
			helperMode = "reply-exit"
			exitCode = 1
			break
		}
		delete(f.networks, args[2])
	case OperationStartContainer, OperationStopContainer, OperationKillContainer, OperationRemoveContainer:
		id := args[1]
		if op == OperationKillContainer {
			id = args[3]
		}
		container, ok := f.containers[id]
		if !ok {
			helperMode = "reply-exit"
			exitCode = 1
			break
		}
		if f.failOperation == op {
			helperMode = "reply-exit"
			exitCode = 7
		} else if op == OperationStartContainer {
			container.Running = true
			container.StateStatus = "running"
		} else if op == OperationStopContainer {
			container.Running = false
			container.StateStatus = "exited"
			container.ExitCode = 0
			container.ExitCodeKnown = true
		} else if op == OperationKillContainer {
			container.Running = false
			container.StateStatus = "exited"
			container.ExitCode = 137
			if f.badKillExit {
				container.ExitCode = 0
			}
			container.ExitCodeKnown = !f.omitKillExitCode
		} else if op == OperationRemoveContainer {
			if container.Network != nil {
				n := f.networks[container.Network.ID]
				delete(n.Consumers, id)
				f.networks[n.ID] = n
			}
			delete(f.containers, id)
		}
		if op != OperationRemoveContainer && f.failOperation != op {
			f.containers[id] = container
		}
	}
	onOperation := f.onOperation
	fail := helperMode == "reply-exit"
	if fail {
		f.failOperation = ""
	}
	f.mu.Unlock()
	if onOperation != nil {
		onOperation(op)
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, -1, err
	}
	if fail {
		return f.child.Run(ctx, helperCommand(f.executable, helperMode, stdout, strconv.Itoa(exitCode)))
	}
	return f.child.Run(ctx, helperCommand(f.executable, "reply", stdout))
}
func (f *fakeRuntimeProcess) inspectJSON(c fakeRuntimeContainer) string {
	type mount struct {
		Type        string `json:"Type"`
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Mode        string `json:"Mode"`
		RW          bool   `json:"RW"`
	}
	data := struct {
		ID     string `json:"Id"`
		Config struct {
			Labels     map[string]string `json:"Labels"`
			Image      string            `json:"Image"`
			Entrypoint []string          `json:"Entrypoint"`
			Cmd        []string          `json:"Cmd"`
			Env        []string          `json:"Env"`
		} `json:"Config"`
		HostConfig struct {
			NetworkMode  string                       `json:"NetworkMode"`
			PidMode      string                       `json:"PidMode"`
			Privileged   bool                         `json:"Privileged"`
			PortBindings map[string][]fakePortBinding `json:"PortBindings"`
		} `json:"HostConfig"`
		State struct {
			Running    bool   `json:"Running"`
			Status     string `json:"Status"`
			ExitCode   *int   `json:"ExitCode"`
			Paused     bool   `json:"Paused"`
			Restarting bool   `json:"Restarting"`
		} `json:"State"`
		Mounts          []mount `json:"Mounts"`
		NetworkSettings struct {
			Networks map[string]struct {
				NetworkID string   `json:"NetworkID"`
				Aliases   []string `json:"Aliases"`
			} `json:"Networks"`
		} `json:"NetworkSettings"`
	}{ID: c.ID}
	data.Config.Labels = c.Labels
	data.Config.Image = c.Image
	data.Config.Entrypoint = c.Entrypoint
	data.Config.Cmd = c.Cmd
	for k, v := range c.Environment {
		data.Config.Env = append(data.Config.Env, k+"="+v)
	}
	sort.Strings(data.Config.Env)
	data.HostConfig.NetworkMode = "none"
	if c.Network != nil {
		data.HostConfig.NetworkMode = c.Network.Name
		data.NetworkSettings.Networks = map[string]struct {
			NetworkID string   `json:"NetworkID"`
			Aliases   []string `json:"Aliases"`
		}{c.Network.Name: {NetworkID: c.Network.ID, Aliases: c.Aliases}}
	}
	data.HostConfig.PortBindings = map[string][]fakePortBinding{}
	for _, p := range c.Ports {
		host, port, _ := net.SplitHostPort(p.Host)
		data.HostConfig.PortBindings[p.Container+"/tcp"] = []fakePortBinding{{HostIP: host, HostPort: port}}
	}
	data.State.Running = c.Running
	data.State.Status = c.StateStatus
	if c.ExitCodeKnown {
		code := c.ExitCode
		data.State.ExitCode = &code
	}
	for _, key := range []string{"source", "control", "evidence", c.ForkKey} {
		mode := "ro"
		rw := false
		target := expectedTarget(key)
		if key == c.ForkKey && c.ForkTarget != "" {
			target = c.ForkTarget
		}
		if key == c.ForkKey {
			mode = "rw"
			rw = true
		}
		data.Mounts = append(data.Mounts, mount{Type: "bind", Source: f.binding.Paths[key], Destination: target, Mode: mode, RW: rw})
	}
	for _, key := range []string{"entrypoint", c.SelectedBinaryRole + "-binary"} {
		if source := f.binding.Paths[key]; source != "" {
			data.Mounts = append(data.Mounts, mount{Type: "bind", Source: source, Destination: expectedTarget(key), Mode: "ro", RW: false})
		}
	}
	b, _ := json.Marshal([]any{data})
	return string(b)
}
func parseFakeMount(raw string) fakeMount {
	m := fakeMount{}
	for _, p := range strings.Split(raw, ",") {
		k, v, ok := strings.Cut(p, "=")
		if !ok {
			continue
		}
		switch k {
		case "src":
			m.Source = v
		case "dst":
			m.Target = v
		case "ro", "readonly":
			m.Mode = "ro"
		case "rw":
			m.Mode = "rw"
		}
	}
	return m
}
func (f *fakeRuntimeProcess) count(op Operation) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	count := 0
	for _, item := range f.operations {
		if item == op {
			count++
		}
	}
	return count
}

type fakeAdoptionAuthorizer struct {
	allow bool
	calls int
}

func (a *fakeAdoptionAuthorizer) AuthorizeAdoption(context.Context, PinnedResource) error {
	a.calls++
	if !a.allow {
		return errors.New("journal intent/resource evidence absent")
	}
	return nil
}
func (a *fakeAdoptionAuthorizer) AuthorizeNetworkAdoption(context.Context, PinnedNetwork) error {
	if !a.allow {
		return errors.New("journal network intent/evidence absent")
	}
	return nil
}

func runtimeFixture(t *testing.T) (*RuntimeAdapter, *fakeRuntimeProcess, *fakeAdoptionAuthorizer, contract.RunBinding, ContainerSpec) {
	t.Helper()
	b := binding(t)
	process := newFakeRuntimeProcess(t, b)
	auth := &fakeAdoptionAuthorizer{}
	a, err := NewRuntimeAdapter(process, process.executable, b, auth)
	if err != nil {
		t.Fatal(err)
	}
	return a, process, auth, b, spec(t, b)
}

func TestRuntimeLifecycleCreateStartStopCleanupAndRepeat(t *testing.T) {
	a, process, _, _, s := runtimeFixture(t)
	ctx := context.Background()
	pin, err := a.Create(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	if pin.ID != fakeContainerID || pin.ForkKey != "fork-a" {
		t.Fatalf("unexpected pin: %+v", pin)
	}
	if err := a.Start(ctx, pin); err != nil {
		t.Fatal(err)
	}
	r, err := a.Inspect(ctx, pin)
	if err != nil || !r.Running {
		t.Fatalf("running resource not inspected: %+v %v", r, err)
	}
	if err := a.Cleanup(ctx, []PinnedResource{pin}); err != nil {
		t.Fatal(err)
	}
	count := len(process.operations)
	if err := a.Cleanup(ctx, []PinnedResource{pin}); err != nil {
		t.Fatalf("repeated cleanup: %v", err)
	}
	if len(process.operations) != count {
		t.Fatalf("repeated cleanup issued runtime calls: %d -> %d", count, len(process.operations))
	}
}

func TestOwnedInternalNetworkLifecycleAndArgv(t *testing.T) {
	a, process, _, _, s := runtimeFixture(t)
	ctx := context.Background()
	network, err := a.CreateInternalNetwork(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if network.ID != fakeNetworkID || network.Name == "" {
		t.Fatalf("unexpected network pin: %+v", network)
	}
	var createArgs []string
	for _, command := range process.commands {
		if command.Operation() == OperationCreateNetwork {
			createArgs = command.Args()
			break
		}
	}
	if len(createArgs) < 5 || strings.Join(createArgs[:5], " ") != "network create --driver bridge --internal" {
		t.Fatalf("unexpected internal-network argv: %q", createArgs)
	}
	if len(process.networks) != 1 || !process.networks[network.ID].Internal {
		t.Fatal("network was not created internal")
	}
	// A port publish request cannot be smuggled into internal-network mode.
	s.Network = &network
	s.Ports = nil
	if err := s.ValidateBinding(process.binding); err != nil {
		t.Fatal(err)
	}
	s.Ports = []Port{{Container: "26657", Host: "127.0.0.1:26657"}}
	if err := s.ValidateBinding(process.binding); !errors.Is(err, ErrUnsafeSpec) {
		t.Fatalf("internal network accepted published port: %v", err)
	}
	s.Ports = nil
	pin, err := a.Create(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	container := process.containers[pin.ID]
	if container.Network == nil || container.Network.ID != network.ID || len(container.Ports) != 0 {
		t.Fatalf("container not attached exclusively: %+v", container)
	}
	if err := a.Cleanup(ctx, []PinnedResource{pin}); err != nil {
		t.Fatal(err)
	}
	if err := a.RemoveInternalNetwork(ctx, network); err != nil {
		t.Fatal(err)
	}
	if err := a.RemoveInternalNetwork(ctx, network); err != nil {
		t.Fatalf("repeated remove: %v", err)
	}
}

func TestCreatePostCreateNetworkVerificationFailureQuarantinesContainer(t *testing.T) {
	for _, failure := range []string{"inspection", "consumer validation"} {
		t.Run(failure, func(t *testing.T) {
			a, process, _, _, s := runtimeFixture(t)
			network, err := a.CreateInternalNetwork(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			s.Network = &network
			s.Ports = nil
			if err := s.ValidateBinding(process.binding); err != nil {
				t.Fatal(err)
			}
			process.onOperation = func(op Operation) {
				if op != OperationCreateContainer {
					return
				}
				process.mu.Lock()
				defer process.mu.Unlock()
				if failure == "inspection" {
					n := process.networks[network.ID]
					n.Internal = false
					process.networks[network.ID] = n
				} else {
					n := process.networks[network.ID]
					n.Consumers["feedface"] = true
					process.networks[network.ID] = n
				}
			}

			pin, err := a.Create(context.Background(), s)
			if !errors.Is(err, ErrMutationUnknown) || pin.ID != fakeContainerID {
				t.Fatalf("post-create verification failure not reported as unknown: pin=%+v err=%v", pin, err)
			}
			before := len(process.commands)
			for _, action := range []struct {
				name string
				call func() error
			}{
				{name: "start", call: func() error { return a.Start(context.Background(), pin) }},
				{name: "stop", call: func() error { return a.Stop(context.Background(), pin) }},
				{name: "remove", call: func() error { return a.Remove(context.Background(), pin) }},
			} {
				if err := action.call(); !errors.Is(err, ErrMutationUnknown) {
					t.Errorf("%s was not rejected for quarantined resource: %v", action.name, err)
				}
			}
			if got := len(process.commands); got != before {
				t.Fatalf("quarantined lifecycle actions issued runtime commands: %d -> %d", before, got)
			}
		})
	}
}

func TestCreateWithVerifiedNetworkRemainsOperational(t *testing.T) {
	a, _, _, _, s := runtimeFixture(t)
	network, err := a.CreateInternalNetwork(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s.Network = &network
	s.Ports = nil
	pin, err := a.Create(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Start(context.Background(), pin); err != nil {
		t.Fatalf("verified network container could not start: %v", err)
	}
	if err := a.Stop(context.Background(), pin); err != nil {
		t.Fatalf("verified network container could not stop: %v", err)
	}
	if err := a.Remove(context.Background(), pin); err != nil {
		t.Fatalf("verified network container could not be removed: %v", err)
	}
}

func TestInternalNetworkCleanupRefusesForeignEndpoint(t *testing.T) {
	a, process, _, _, _ := runtimeFixture(t)
	network, err := a.CreateInternalNetwork(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	n := process.networks[network.ID]
	n.Consumers[fakeContainerID] = true
	process.networks[network.ID] = n
	if err := a.RemoveInternalNetwork(context.Background(), network); !errors.Is(err, ErrForeignResource) {
		t.Fatalf("foreign endpoint accepted: %v", err)
	}
	if _, ok := process.networks[network.ID]; !ok {
		t.Fatal("foreign-consumer network was removed")
	}
}

func TestInternalNetworkInterruptedCreateIsUnknownAndNotRepeated(t *testing.T) {
	a, process, _, _, _ := runtimeFixture(t)
	process.failOperation = OperationCreateNetwork
	if _, err := a.CreateInternalNetwork(context.Background()); !errors.Is(err, ErrMutationUnknown) {
		t.Fatalf("create failure not quarantined: %v", err)
	}
	creates := process.count(OperationCreateNetwork)
	if _, err := a.CreateInternalNetwork(context.Background()); !errors.Is(err, ErrMutationUnknown) || process.count(OperationCreateNetwork) != creates {
		t.Fatal("unknown network create was repeated")
	}
}

func recoveryRuntimeFixture(t *testing.T) (*RuntimeAdapter, *fakeRuntimeProcess, ContainerSpec, contract.RunBinding, *fakeAdoptionAuthorizer) {
	t.Helper()
	_, process, auth, b, s := runtimeFixture(t)
	entry := filepath.Join(b.Workspace, "recovery-entrypoint.sh")
	recoveryBinary := filepath.Join(b.Workspace, "recovery-inferenced")
	originalBinary := filepath.Join(b.Workspace, "original-inferenced")
	if err := os.WriteFile(entry, []byte("#!/bin/sh\nexec /root/gnklab0002/selected/inferenced \"$@\"\n"), 0500); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recoveryBinary, []byte("recovery binary"), 0500); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(originalBinary, []byte("original binary"), 0500); err != nil {
		t.Fatal(err)
	}
	entryData, _ := os.ReadFile(entry)
	recoveryData, _ := os.ReadFile(recoveryBinary)
	originalData, _ := os.ReadFile(originalBinary)
	b.Paths["entrypoint"] = entry
	b.Paths["recovery-binary"] = recoveryBinary
	b.Paths["original-binary"] = originalBinary
	b.InputDigests["recovery-entrypoint"] = contract.PayloadDigest(entryData)
	b.InputDigests["recovery-binary"] = contract.PayloadDigest(recoveryData)
	b.InputDigests["original-binary"] = contract.PayloadDigest(originalData)
	process.binding = cloneRunBinding(b)
	a, err := NewRuntimeAdapter(process, process.executable, b, auth)
	if err != nil {
		t.Fatal(err)
	}
	digest, _ := contract.Digest(b)
	s.Image = "registry.invalid/recovery@sha256:" + strings.Repeat("a", 64)
	s.Name = "recovery-node"
	s.Ports = nil
	s.ForkTarget = "/root/.inference"
	for i := range s.Mounts {
		if s.Mounts[i].PathKey == "fork-a" {
			s.Mounts[i].Target = "/root/.inference"
		}
	}
	s.Entrypoint = []string{"sh", "/root/gnklab0002/recovery-entrypoint.sh"}
	s.SelectedBinaryRole = "recovery"
	s.Argv = []string{"start", "--home", "/root/.inference"}
	s.Environment = map[string]string{"GNK_LAB_SELECTED_BINARY_ROLE": "recovery", "GNK_LAB_RECOVERY_BINARY_SHA256": b.InputDigests["recovery-binary"], "GNK_LAB_ORIGINAL_BINARY_SHA256": b.InputDigests["original-binary"], "GNK_LAB_RECOVERY_BARRIER_CHAIN_ID": b.ChainID, "GNK_LAB_RECOVERY_BARRIER_DIR": "/root/.inference/gnklab0002-recovery-barrier"}
	s.Mounts = append(s.Mounts, Mount{PathKey: "entrypoint", Target: "/root/gnklab0002/recovery-entrypoint.sh", ReadOnly: true}, Mount{PathKey: "recovery-binary", Target: "/root/gnklab0002/selected/inferenced", ReadOnly: true})
	s.Labels = map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": digest}
	return a, process, s, b, auth
}

func TestRecoveryContainerUsesBoundCommandEnvMountAndAliases(t *testing.T) {
	a, process, s, b, _ := recoveryRuntimeFixture(t)
	network, err := a.CreateInternalNetwork(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s.Network = &network
	s.DNSAliases = []string{"gnk2-genesis-node"}
	command, err := s.createCommand(process.executable, b)
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(command.Args(), " ")
	for _, want := range []string{"--entrypoint sh", "--env GNK_LAB_SELECTED_BINARY_ROLE=recovery", "--network-alias gnk2-genesis-node", "dst=/root/.inference,rw", "dst=/root/gnklab0002/recovery-entrypoint.sh,readonly", "dst=/root/gnklab0002/selected/inferenced,readonly"} {
		if !strings.Contains(args, want) {
			t.Fatalf("missing %q from argv %q", want, args)
		}
	}
	pin, err := a.Create(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if pin.ForkTarget != "/root/.inference" || len(pin.DNSAliases) != 1 || pin.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] != "recovery" {
		t.Fatalf("runtime policy not durably pinned: %+v", pin)
	}
	if _, err := a.Inspect(context.Background(), pin); err != nil {
		t.Fatalf("exact inspect rejected: %v", err)
	}
}

func TestKillRecoveryUsesExactKILLArgvAndVerifies137(t *testing.T) {
	a, process, spec, _, _ := recoveryRuntimeFixture(t)
	ctx := context.Background()
	pin, err := a.Create(ctx, spec)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Start(ctx, pin); err != nil {
		t.Fatal(err)
	}
	if err := a.KillRecovery(ctx, pin); err != nil {
		t.Fatal(err)
	}
	if process.count(OperationKillContainer) != 1 {
		t.Fatalf("expected one hard kill, got %d", process.count(OperationKillContainer))
	}
	for _, command := range process.commands {
		if command.Operation() == OperationKillContainer && !reflect.DeepEqual(command.Args(), []string{"kill", "--signal", "KILL", pin.ID}) {
			t.Fatalf("unexpected kill argv: %#v", command.Args())
		}
	}
	resource, err := a.Inspect(ctx, pin)
	if err != nil || resource.Running || resource.StateStatus != "exited" || !resource.ExitCodeKnown || resource.ExitCode != 137 {
		t.Fatalf("hard-stop receipt was not inspect-verified: %+v %v", resource, err)
	}
}

func TestKillRecoveryRefusesUnstartedOriginalStaleAndForeignPins(t *testing.T) {
	t.Run("unstarted", func(t *testing.T) {
		a, p, s, _, _ := recoveryRuntimeFixture(t)
		pin, err := a.Create(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if err := a.KillRecovery(context.Background(), pin); err == nil || p.count(OperationKillContainer) != 0 {
			t.Fatalf("unstarted container was killed: err=%v kills=%d", err, p.count(OperationKillContainer))
		}
	})
	t.Run("original role", func(t *testing.T) {
		a, p, s, _, _ := recoveryRuntimeFixture(t)
		s.SelectedBinaryRole = BinaryOriginal
		s.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] = string(BinaryOriginal)
		s.Mounts[len(s.Mounts)-1] = Mount{PathKey: "original-binary", Target: "/root/gnklab0002/selected/inferenced", ReadOnly: true}
		pin, err := a.Create(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if err := a.Start(context.Background(), pin); err != nil {
			t.Fatal(err)
		}
		if err := a.KillRecovery(context.Background(), pin); !errors.Is(err, ErrForeignResource) || p.count(OperationKillContainer) != 0 {
			t.Fatalf("original role was eligible for recovery kill: err=%v kills=%d", err, p.count(OperationKillContainer))
		}
	})
	t.Run("stale pin", func(t *testing.T) {
		a, p, s, _, _ := recoveryRuntimeFixture(t)
		pin, err := a.Create(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if err := a.Start(context.Background(), pin); err != nil {
			t.Fatal(err)
		}
		pin.SelectedBinaryDigest = strings.Repeat("f", 64)
		if err := a.KillRecovery(context.Background(), pin); !errors.Is(err, ErrForeignResource) || p.count(OperationKillContainer) != 0 {
			t.Fatalf("stale pin was accepted: err=%v kills=%d", err, p.count(OperationKillContainer))
		}
	})
	t.Run("foreign labels", func(t *testing.T) {
		a, p, s, _, _ := recoveryRuntimeFixture(t)
		pin, err := a.Create(context.Background(), s)
		if err != nil {
			t.Fatal(err)
		}
		if err := a.Start(context.Background(), pin); err != nil {
			t.Fatal(err)
		}
		container := p.containers[pin.ID]
		container.Labels["gonka.rehearsal.owner"] = "other-owner"
		p.containers[pin.ID] = container
		if err := a.KillRecovery(context.Background(), pin); !errors.Is(err, ErrForeignResource) || p.count(OperationKillContainer) != 0 {
			t.Fatalf("foreign resource was killed: err=%v kills=%d", err, p.count(OperationKillContainer))
		}
	})
}

func TestKillRecoveryQuarantinesCommandAndVerificationFailures(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(*fakeRuntimeProcess)
	}{
		{"daemon error", func(p *fakeRuntimeProcess) { p.failOperation = OperationKillContainer }},
		{"wrong exit status", func(p *fakeRuntimeProcess) { p.badKillExit = true }},
		{"missing exit status", func(p *fakeRuntimeProcess) { p.omitKillExitCode = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, p, s, _, _ := recoveryRuntimeFixture(t)
			pin, err := a.Create(context.Background(), s)
			if err != nil {
				t.Fatal(err)
			}
			if err := a.Start(context.Background(), pin); err != nil {
				t.Fatal(err)
			}
			tc.setup(p)
			if err := a.KillRecovery(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) {
				t.Fatalf("failure did not produce unknown outcome: %v", err)
			}
			count := p.count(OperationKillContainer)
			if err := a.KillRecovery(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) || p.count(OperationKillContainer) != count {
				t.Fatalf("uncertain kill was retried: err=%v kills=%d -> %d", err, count, p.count(OperationKillContainer))
			}
		})
	}
}

func TestRecoveryInspectRejectsEntrypointEnvironmentAliasAndMountSubstitutions(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*fakeRuntimeContainer)
	}{
		{"entrypoint", func(c *fakeRuntimeContainer) { c.Entrypoint = []string{"/bin/sh"} }},
		{"command", func(c *fakeRuntimeContainer) { c.Cmd = []string{"start", "--home", "/tmp"} }},
		{"environment", func(c *fakeRuntimeContainer) {
			c.Environment["GNK_LAB_RECOVERY_BINARY_SHA256"] = strings.Repeat("f", 64)
		}},
		{"dns alias", func(c *fakeRuntimeContainer) { c.Aliases[0] = "foreign-alias" }},
		{"fork target", func(c *fakeRuntimeContainer) { c.ForkTarget = "/tmp" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a, p, s, _, _ := recoveryRuntimeFixture(t)
			n, err := a.CreateInternalNetwork(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			s.Network = &n
			s.DNSAliases = []string{"gnk2-genesis-node"}
			pin, err := a.Create(context.Background(), s)
			if err != nil {
				t.Fatal(err)
			}
			c := p.containers[pin.ID]
			tc.mutate(&c)
			p.containers[pin.ID] = c
			_, err = a.Inspect(context.Background(), pin)
			if !errors.Is(err, ErrUnsafeSpec) {
				t.Fatalf("substitution accepted: %v", err)
			}
			if strings.Contains(err.Error(), s.Environment["GNK_LAB_RECOVERY_BINARY_SHA256"]) {
				t.Fatal("environment value leaked in failure")
			}
		})
	}
}

func TestRecoveryPolicyRejectsUnapprovedEnvShellAndUnownedAliases(t *testing.T) {
	_, _, base, b, _ := recoveryRuntimeFixture(t)
	cases := []struct {
		name   string
		mutate func(*ContainerSpec)
	}{
		{"unknown env", func(s *ContainerSpec) { s.Environment["AWS_SECRET_ACCESS_KEY"] = "must-not-be-accepted" }},
		{"unbound selected binary", func(s *ContainerSpec) { s.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] = "other" }},
		{"shell command parsing", func(s *ContainerSpec) { s.Entrypoint = []string{"sh", "-c", "/bin/true"} }},
		{"wrong target", func(s *ContainerSpec) {
			s.ForkTarget = "/root"
			for i := range s.Mounts {
				if s.Mounts[i].PathKey == "fork-a" {
					s.Mounts[i].Target = "/root"
				}
			}
		}},
		{"aliases without owned network", func(s *ContainerSpec) { s.Network = nil; s.DNSAliases = []string{"node"} }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := base
			s.Environment = cloneStringMap(base.Environment)
			s.Entrypoint = append([]string(nil), base.Entrypoint...)
			s.Mounts = append([]Mount(nil), base.Mounts...)
			tc.mutate(&s)
			if err := s.ValidateBinding(b); !errors.Is(err, ErrUnsafeSpec) {
				t.Fatalf("unsafe recovery spec accepted: %v", err)
			}
		})
	}
}

func TestRecoveryFilesMustMatchBoundHostDigestsBeforeCreate(t *testing.T) {
	a, p, s, _, _ := recoveryRuntimeFixture(t)
	if err := os.Chmod(p.binding.Paths["recovery-binary"], 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p.binding.Paths["recovery-binary"], []byte("substituted binary"), 0500); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Create(context.Background(), s); !errors.Is(err, ErrUnsafeSpec) {
		t.Fatalf("changed host binary accepted: %v", err)
	}
	if p.count(OperationCreateContainer) != 0 {
		t.Fatal("container create occurred before host file digest verification")
	}
}

func TestRecoveryAndOriginalUseTwoBoundBinaryPinsUnderSameBinding(t *testing.T) {
	a, p, recovery, b, auth := recoveryRuntimeFixture(t)
	recoveryPin, err := a.Create(context.Background(), recovery)
	if err != nil {
		t.Fatal(err)
	}
	auth.allow = true
	recoveryAdopter, err := NewRuntimeAdapter(p, p.executable, b, auth)
	if err != nil {
		t.Fatal(err)
	}
	if err := recoveryAdopter.Adopt(context.Background(), recoveryPin); err != nil {
		t.Fatalf("recovery binary adoption failed: %v", err)
	}
	if err := recoveryAdopter.Cleanup(context.Background(), []PinnedResource{recoveryPin}); err != nil {
		t.Fatalf("recovery cleanup before original transition failed: %v", err)
	}
	original := recovery
	original.Name = "original-node"
	original.SelectedBinaryRole = "original"
	original.Entrypoint = append([]string(nil), recovery.Entrypoint...)
	original.Argv = append([]string(nil), recovery.Argv...)
	original.Environment = cloneStringMap(recovery.Environment)
	original.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] = "original"
	original.Mounts = append([]Mount(nil), recovery.Mounts...)
	for i := range original.Mounts {
		if original.Mounts[i].PathKey == "recovery-binary" {
			original.Mounts[i].PathKey = "original-binary"
		}
	}
	originalPin, err := a.Create(context.Background(), original)
	if err != nil {
		t.Fatal(err)
	}
	if recoveryPin.BindingDigest != originalPin.BindingDigest {
		t.Fatal("switching selected binary changed immutable run binding")
	}
	if recoveryPin.SelectedBinaryRole != "recovery" || recoveryPin.SelectedBinaryPath != b.Paths["recovery-binary"] || recoveryPin.SelectedBinaryDigest != b.InputDigests["recovery-binary"] || originalPin.SelectedBinaryRole != "original" || originalPin.SelectedBinaryPath != b.Paths["original-binary"] || originalPin.SelectedBinaryDigest != b.InputDigests["original-binary"] {
		t.Fatalf("incorrect binary pins: recovery=%+v original=%+v", recoveryPin, originalPin)
	}
	adopter, err := NewRuntimeAdapter(p, p.executable, b, auth)
	if err != nil {
		t.Fatal(err)
	}
	if err := adopter.Adopt(context.Background(), originalPin); err != nil {
		t.Fatalf("original binary adoption failed: %v", err)
	}
	for name, mutate := range map[string]func(*PinnedResource){"role": func(p *PinnedResource) { p.SelectedBinaryRole = "original" }, "path": func(p *PinnedResource) { p.SelectedBinaryPath = b.Paths["original-binary"] }, "digest": func(p *PinnedResource) { p.SelectedBinaryDigest = strings.Repeat("f", 64) }} {
		t.Run("adoption rejects altered "+name, func(t *testing.T) {
			pin := recoveryPin
			mutate(&pin)
			if err := adopter.Adopt(context.Background(), pin); !errors.Is(err, ErrAdoptionDenied) {
				t.Fatalf("tampered binary selection adopted: %v", err)
			}
		})
	}
}

func TestRecoveryBinaryRolePathAndDigestMustAgree(t *testing.T) {
	_, _, base, b, _ := recoveryRuntimeFixture(t)
	cases := []struct {
		name   string
		mutate func(*ContainerSpec, *contract.RunBinding)
	}{
		{"role and environment disagree", func(s *ContainerSpec, b *contract.RunBinding) { s.SelectedBinaryRole = "original" }},
		{"role and source path disagree", func(s *ContainerSpec, _ *contract.RunBinding) {
			s.SelectedBinaryRole = "original"
			s.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] = "original"
		}},
		{"original digest substituted", func(s *ContainerSpec, _ *contract.RunBinding) {
			s.Environment["GNK_LAB_ORIGINAL_BINARY_SHA256"] = strings.Repeat("f", 64)
		}},
		{"binary paths alias", func(_ *ContainerSpec, b *contract.RunBinding) {
			b.Paths["original-binary"] = b.Paths["recovery-binary"]
		}},
		{"missing original path", func(_ *ContainerSpec, b *contract.RunBinding) { delete(b.Paths, "original-binary") }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := base
			s.Mounts = append([]Mount(nil), base.Mounts...)
			s.Environment = cloneStringMap(base.Environment)
			bindingCopy := cloneRunBinding(b)
			tc.mutate(&s, &bindingCopy)
			if err := s.ValidateBinding(bindingCopy); !errors.Is(err, ErrUnsafeSpec) {
				t.Fatalf("mismatched binary policy accepted: %v", err)
			}
		})
	}
}

func TestRuntimeLifecycleRequiresPreloadedPinnedImage(t *testing.T) {
	a, process, _, _, s := runtimeFixture(t)
	process.failOperation = OperationInspectImage
	if _, err := a.Create(context.Background(), s); err == nil {
		t.Fatal("create proceeded without a locally inspectable pinned image")
	}
	if process.count(OperationCreateContainer) != 0 {
		t.Fatal("create executed before image inspection")
	}
}

func TestLocalImageContentIDRequiresExactInspectID(t *testing.T) {
	a, process, _, _, s := runtimeFixture(t)
	localID := "sha256:" + strings.Repeat("9", 64)
	s.Image = localID
	process.imageInspectID = localID
	process.imageRepoDigests = []string{}
	if _, err := a.Create(context.Background(), s); err != nil {
		t.Fatalf("exact local image ID rejected: %v", err)
	}
	a2, p2, _, _, s2 := runtimeFixture(t)
	s2.Image = localID
	p2.imageInspectID = "sha256:" + strings.Repeat("8", 64)
	p2.imageRepoDigests = []string{}
	if _, err := a2.Create(context.Background(), s2); !errors.Is(err, ErrUnsafeSpec) {
		t.Fatalf("mismatched local image ID accepted: %v", err)
	}
}

func TestRuntimeLifecycleRefusesForeignAndUnpinnedResources(t *testing.T) {
	a, process, auth, b, _ := runtimeFixture(t)
	digest, _ := contract.Digest(b)
	pin := PinnedResource{ID: fakeContainerID, Name: "fork-a", RunID: b.RunID, OwnershipMarker: b.OwnershipMarker, BindingDigest: digest, ForkKey: "fork-a", Image: "registry.invalid/node@sha256:" + strings.Repeat("a", 64), Ports: []Port{{Container: "26657", Host: "127.0.0.1:26657"}}, Argv: []string{"node", "start"}}
	labels := map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": "foreign", "gonka.rehearsal.binding": digest}
	process.containers[pin.ID] = fakeRuntimeContainer{ID: pin.ID, Labels: labels, ForkKey: "fork-a", Image: pin.Image, Ports: pin.Ports}
	if err := a.Start(context.Background(), pin); !errors.Is(err, ErrForeignResource) {
		t.Fatalf("start accepted foreign resource: %v", err)
	}
	if auth.calls != 0 {
		t.Fatal("ordinary start invoked adoption gate")
	}
	if err := a.Adopt(context.Background(), pin); !errors.Is(err, ErrAdoptionDenied) {
		t.Fatalf("pin alone authorized adoption: %v", err)
	}
	auth.allow = true
	if err := a.Adopt(context.Background(), pin); !errors.Is(err, ErrForeignResource) {
		t.Fatalf("adopt accepted foreign resource: %v", err)
	}
	if process.count(OperationStartContainer) != 0 || process.count(OperationRemoveContainer) != 0 {
		t.Fatal("foreign resource was mutated")
	}
	if err := a.Remove(context.Background(), pin); !errors.Is(err, ErrForeignResource) {
		t.Fatalf("untracked pin authorized removal: %v", err)
	}
}

func TestRuntimeLifecycleRejectsChangedRuntimeConfiguration(t *testing.T) {
	a, process, auth, b, _ := runtimeFixture(t)
	digest, _ := contract.Digest(b)
	pin := PinnedResource{ID: fakeContainerID, Name: "fork-a", RunID: b.RunID, OwnershipMarker: b.OwnershipMarker, BindingDigest: digest, ForkKey: "fork-a", Image: "registry.invalid/node@sha256:" + strings.Repeat("a", 64), Ports: []Port{{Container: "26657", Host: "127.0.0.1:26657"}}, Argv: []string{"node", "start"}}
	labels := map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": digest}
	process.containers[pin.ID] = fakeRuntimeContainer{ID: pin.ID, Labels: labels, ForkKey: "fork-a", Image: pin.Image, Ports: []Port{{Container: "26657", Host: "0.0.0.0:26657"}}}
	auth.allow = true
	if err := a.Adopt(context.Background(), pin); !errors.Is(err, ErrUnsafeSpec) {
		t.Fatalf("changed published port binding accepted: %v", err)
	}
	if process.count(OperationStartContainer)+process.count(OperationStopContainer)+process.count(OperationRemoveContainer) != 0 {
		t.Fatal("invalid runtime configuration mutated")
	}
}

func TestRuntimeLifecycleInterruptedCreateRequiresJournalAdoption(t *testing.T) {
	a, process, auth, _, s := runtimeFixture(t)
	process.failOperation = OperationCreateContainer
	pin, err := a.Create(context.Background(), s)
	if !errors.Is(err, ErrMutationUnknown) || !errors.Is(err, ErrProcessExit) || pin.ID != fakeContainerID {
		t.Fatalf("interrupted create not reported with pin: %+v %v", pin, err)
	}
	if err := a.Start(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) {
		t.Fatalf("unknown create outcome allowed start: %v", err)
	}
	if err := a.Adopt(context.Background(), pin); !errors.Is(err, ErrAdoptionDenied) {
		t.Fatalf("pin alone authorized adoption: %v", err)
	}
	auth.allow = true
	if err := a.Adopt(context.Background(), pin); err != nil {
		t.Fatalf("journal-authorized adoption failed: %v", err)
	}
	if err := a.Cleanup(context.Background(), []PinnedResource{pin}); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeLifecycleMutationFailureAndCancellationQuarantine(t *testing.T) {
	a, process, auth, _, s := runtimeFixture(t)
	pin, err := a.Create(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	process.failOperation = OperationStartContainer
	if err := a.Start(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) {
		t.Fatalf("failed start not quarantined: %v", err)
	}
	starts := process.count(OperationStartContainer)
	if err := a.Start(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) || process.count(OperationStartContainer) != starts {
		t.Fatal("unknown start was repeated")
	}
	auth.allow = true
	if err := a.Adopt(context.Background(), pin); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	process.onOperation = func(op Operation) {
		if op == OperationStartContainer {
			cancel()
		}
	}
	err = a.Start(ctx, pin)
	process.onOperation = nil
	if !errors.Is(err, ErrMutationUnknown) || !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled start not quarantined promptly: %v", err)
	}
	starts = process.count(OperationStartContainer)
	if err := a.Start(context.Background(), pin); !errors.Is(err, ErrMutationUnknown) || process.count(OperationStartContainer) != starts {
		t.Fatal("canceled start was repeated")
	}
	if err := a.Adopt(context.Background(), pin); err != nil {
		t.Fatalf("reconcile running resource: %v", err)
	}
	if err := a.Cleanup(context.Background(), []PinnedResource{pin}); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeLifecycleInspectCancellationDoesNotMutate(t *testing.T) {
	a, process, auth, b, _ := runtimeFixture(t)
	digest, _ := contract.Digest(b)
	pin := PinnedResource{ID: fakeContainerID, Name: "fork-a", RunID: b.RunID, OwnershipMarker: b.OwnershipMarker, BindingDigest: digest, ForkKey: "fork-a", Image: "registry.invalid/node@sha256:" + strings.Repeat("a", 64), Ports: []Port{{Container: "26657", Host: "127.0.0.1:26657"}}, Argv: []string{"node", "start"}}
	labels := map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": digest}
	process.containers[pin.ID] = fakeRuntimeContainer{ID: pin.ID, Labels: labels, ForkKey: "fork-a", Image: pin.Image, Ports: pin.Ports}
	auth.allow = true
	ctx, cancel := context.WithCancel(context.Background())
	process.onOperation = func(op Operation) {
		if op == OperationInspectResources {
			cancel()
		}
	}
	err := a.Adopt(ctx, pin)
	process.onOperation = nil
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("inspection cancellation lost: %v", err)
	}
	if process.count(OperationStartContainer)+process.count(OperationStopContainer)+process.count(OperationRemoveContainer) != 0 {
		t.Fatal("inspection cancellation caused mutation")
	}
}
