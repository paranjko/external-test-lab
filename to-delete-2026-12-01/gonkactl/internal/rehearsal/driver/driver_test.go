package driver

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
)

const testImage = "registry.invalid/node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type memoryJournal struct {
	mu           sync.Mutex
	ledger       Ledger
	pending      *Step
	unknown      bool
	failComplete Step
}

func newMemoryJournal(digest string) *memoryJournal {
	return &memoryJournal{ledger: Ledger{BindingDigest: digest}}
}
func (j *memoryJournal) Read(_ context.Context, digest string) (Ledger, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if digest != j.ledger.BindingDigest {
		return Ledger{}, ErrPrecondition
	}
	out := j.ledger
	out.Completed = append([]Record(nil), j.ledger.Completed...)
	if j.pending != nil {
		p := *j.pending
		out.Pending = &p
	}
	out.Unknown = j.unknown
	return out, nil
}
func (j *memoryJournal) Begin(_ context.Context, digest string, step Step, _ json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if digest != j.ledger.BindingDigest || j.pending != nil || j.unknown || len(j.ledger.Completed) >= len(orderedSteps) || orderedSteps[len(j.ledger.Completed)] != step {
		return ErrPrecondition
	}
	j.pending = &step
	return nil
}
func (j *memoryJournal) Complete(_ context.Context, digest string, step Step, raw json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if digest != j.ledger.BindingDigest || j.pending == nil || *j.pending != step {
		return ErrPrecondition
	}
	if j.failComplete == step {
		return errors.New("simulated persistence failure")
	}
	j.ledger.Completed = append(j.ledger.Completed, Record{Step: step, Evidence: append([]byte(nil), raw...)})
	j.pending = nil
	return nil
}
func (j *memoryJournal) Record(_ context.Context, digest string, step Step, raw json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if digest != j.ledger.BindingDigest || j.pending != nil || j.unknown || len(j.ledger.Completed) >= len(orderedSteps) || orderedSteps[len(j.ledger.Completed)] != step {
		return ErrPrecondition
	}
	j.ledger.Completed = append(j.ledger.Completed, Record{Step: step, Evidence: append([]byte(nil), raw...)})
	return nil
}
func (j *memoryJournal) Unknown(_ context.Context, digest string, step Step, _ string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if digest != j.ledger.BindingDigest || j.pending == nil || *j.pending != step {
		return ErrPrecondition
	}
	j.unknown = true
	return nil
}
func (j *memoryJournal) AuthorizeAdoption(_ context.Context, pin isolation.PinnedResource) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	for _, record := range j.ledger.Completed {
		if record.Step != ControlCreate && record.Step != RecoveryCreate && record.Step != StandardCreate {
			continue
		}
		var stored isolation.PinnedResource
		if contract.DecodeStrict(record.Evidence, &stored) == nil && reflect.DeepEqual(stored, pin) {
			return nil
		}
	}
	return ErrPrecondition
}

type testContainer struct {
	spec     isolation.ContainerSpec
	id       string
	running  bool
	status   string
	exit     int
	hostname string
	pid      int
}
type fakeDocker struct {
	mu           sync.Mutex
	binding      contract.RunBinding
	plan         Plan
	containers   map[string]*testContainer
	ops          []string
	containerSeq int
	writeMarker  bool
}

func (f *fakeDocker) Run(ctx context.Context, cmd isolation.Command) ([]byte, []byte, int, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, -1, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	args := cmd.Args()
	if len(args) == 0 {
		return nil, nil, 1, errors.New("empty argv")
	}
	switch cmd.Operation() {
	case isolation.OperationInspectImage:
		raw, err := json.Marshal([]map[string]any{{"Id": args[2], "RepoDigests": []string{args[2]}}})
		return raw, nil, 0, err
	case isolation.OperationCreateContainer:
		name := args[2]
		spec := f.spec(name)
		if spec.Name == "" {
			return nil, nil, 1, fmt.Errorf("unexpected container %q", name)
		}
		f.containerSeq++
		id := fmt.Sprintf("%064x", f.containerSeq)
		c := &testContainer{spec: spec, id: id, status: "created", hostname: id[:12], pid: 1000 + f.containerSeq}
		f.containers[id] = c
		f.ops = append(f.ops, "create:"+name)
		return []byte(id), nil, 0, nil
	case isolation.OperationInspectResources:
		id := args[len(args)-1]
		c := f.containers[id]
		if c == nil {
			return nil, []byte("not found"), 1, nil
		}
		f.ops = append(f.ops, "inspect:"+c.spec.Name)
		return f.inspectJSON(c), nil, 0, nil
	case isolation.OperationStartContainer:
		c := f.containers[args[1]]
		if c == nil {
			return nil, nil, 1, errors.New("not found")
		}
		f.ops = append(f.ops, "start:"+c.spec.Name)
		c.running, c.status, c.exit = true, "running", 0
		if c.spec.Name == f.plan.Recovery.Name && f.writeMarker {
			f.writeRecoveryMarker(c)
		}
		return nil, nil, 0, nil
	case isolation.OperationStopContainer:
		c := f.containers[args[1]]
		if c == nil {
			return nil, nil, 1, errors.New("not found")
		}
		f.ops = append(f.ops, "stop:"+c.spec.Name)
		c.running, c.status, c.exit = false, "exited", 0
		return nil, nil, 0, nil
	case isolation.OperationKillContainer:
		c := f.containers[args[3]]
		if c == nil {
			return nil, nil, 1, errors.New("not found")
		}
		f.ops = append(f.ops, "kill:"+c.spec.Name)
		c.running, c.status, c.exit = false, "exited", 137
		return nil, nil, 0, nil
	default:
		return nil, nil, 1, fmt.Errorf("unexpected operation %s", cmd.Operation())
	}
}
func (f *fakeDocker) spec(name string) isolation.ContainerSpec {
	for _, s := range []isolation.ContainerSpec{f.plan.Control, f.plan.Recovery, f.plan.Standard} {
		if s.Name == name {
			return s
		}
	}
	return isolation.ContainerSpec{}
}
func (f *fakeDocker) writeRecoveryMarker(c *testContainer) {
	name := barrierFilename(f.plan.Barrier.Stage, f.plan.Barrier.Height)
	marker := coregate.BarrierMarker{ChainID: f.plan.Barrier.ChainID, Height: f.plan.Barrier.Height, Stage: f.plan.Barrier.Stage, AppHash: f.plan.Barrier.AppHash, BlockID: strings.ToUpper(f.plan.Barrier.BlockHash) + fmt.Sprintf("/%d:%s", f.plan.Barrier.PartSetTotal, strings.ToUpper(f.plan.Barrier.PartSetHash)), Hostname: c.hostname, PID: 1}
	raw, _ := json.Marshal(marker)
	path := filepath.Join(f.binding.Paths[selectedFork(f.plan.Recovery)], "gnklab0002-recovery-barrier", name)
	_ = os.WriteFile(path, append(raw, '\n'), 0o600)
}
func (f *fakeDocker) inspectJSON(c *testContainer) []byte {
	type mount struct {
		Type        string `json:"Type"`
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Mode        string `json:"Mode"`
		RW          bool   `json:"RW"`
	}
	data := map[string]any{"Id": c.id, "Config": map[string]any{"Labels": c.spec.Labels, "Image": c.spec.Image, "Hostname": c.hostname, "Entrypoint": []string{c.spec.Entrypoint[0]}, "Cmd": append(append([]string{}, c.spec.Entrypoint[1:]...), c.spec.Argv...)}, "HostConfig": map[string]any{"NetworkMode": "none", "PidMode": "", "IpcMode": "", "UTSMode": "", "UsernsMode": "", "CgroupnsMode": "", "Privileged": false, "CapAdd": []string{}, "Devices": []any{}, "SecurityOpt": []string{}, "PortBindings": map[string]any{}}, "State": map[string]any{"Running": c.running, "Status": c.status, "ExitCode": c.exit, "Paused": false, "Restarting": false, "Pid": c.pid}, "NetworkSettings": map[string]any{"Networks": map[string]any{}}, "Mounts": []mount{}}
	env := []string{}
	for k, v := range c.spec.Environment {
		env = append(env, k+"="+v)
	}
	sort.Strings(env)
	data["Config"].(map[string]any)["Env"] = env
	mounts := []mount{}
	for _, m := range c.spec.Mounts {
		mode, rw := "ro", false
		if !m.ReadOnly {
			mode, rw = "rw", true
		}
		mounts = append(mounts, mount{Type: "bind", Source: f.binding.Paths[m.PathKey], Destination: m.Target, Mode: mode, RW: rw})
	}
	data["Mounts"] = mounts
	raw, _ := json.Marshal([]any{data})
	return raw
}

type fakeHooks struct {
	docker                *fakeDocker
	plan                  Plan
	events                []string
	mutateRecoveryBinary  bool
	offlineUnavailable    bool
	standardReady         bool
	corruptHandoffDigest  bool
	corruptHPlusOneDigest bool
	hplusRaw              []byte
}

func (h *fakeHooks) ObserveControlFailure(_ context.Context, b contract.RunBinding, p isolation.PinnedResource) (ControlFailureEvidence, error) {
	h.events = append(h.events, "control.failure")
	c := h.docker.containers[p.ID]
	c.running, c.status, c.exit = false, "exited", 23
	claim := controlFailureRecord{RunID: b.RunID, BindingDigest: bindingDigest(b), RuntimeID: p.ID, FailureKind: "expected-control-rejection", ExitCode: 23}
	raw, _ := json.Marshal(claim)
	if h.mutateRecoveryBinary {
		_ = os.Chmod(b.Paths["recovery-binary"], 0o600)
		_ = os.WriteFile(b.Paths["recovery-binary"], []byte("substituted binary"), 0o600)
	}
	return ControlFailureEvidence{RunID: b.RunID, BindingDigest: bindingDigest(b), RuntimeID: p.ID, FailureKind: claim.FailureKind, ExitCode: 23, RawSHA256: contract.PayloadDigest(raw), Raw: raw}, nil
}
func (h *fakeHooks) ReadOfflineStores(_ context.Context, b contract.RunBinding, p isolation.PinnedResource) ([]OfflineStoreSnapshot, error) {
	h.events = append(h.events, "stores.read")
	if h.offlineUnavailable {
		return nil, ErrUnavailable
	}
	out := []OfflineStoreSnapshot{}
	for _, store := range []string{"application", "comet-state", "block-store"} {
		snap := contract.Snapshot{Stores: []contract.LogicalStore{{Name: store, Entries: []contract.Entry{}}}}
		raw, _ := json.Marshal(snap)
		out = append(out, OfflineStoreSnapshot{SchemaVersion: contract.Version, RunID: b.RunID, BindingDigest: bindingDigest(b), NodeID: h.plan.NodeID, RuntimeID: p.ID, Store: store, Height: h.plan.Barrier.Height, AppHash: h.plan.Barrier.AppHash, BlockID: strings.ToUpper(h.plan.Barrier.BlockHash), PartSetHash: strings.ToUpper(h.plan.Barrier.PartSetHash), PartSetTotal: h.plan.Barrier.PartSetTotal, RawSnapshot: raw})
	}
	return out, nil
}
func (h *fakeHooks) VerifyStandardHandoff(_ context.Context, b contract.RunBinding, r, s isolation.PinnedResource) (HandoffEvidence, error) {
	h.events = append(h.events, "handoff")
	if !h.docker.containers[s.ID].running {
		return HandoffEvidence{}, ErrPrecondition
	}
	h.standardReady = true
	claim := handoffRecord{RunID: b.RunID, BindingDigest: bindingDigest(b), RecoveryID: r.ID, StandardID: s.ID, RecoveryBinaryDigest: r.SelectedBinaryDigest, StandardBinaryDigest: s.SelectedBinaryDigest, RecoveryProcessedHeight: h.plan.Barrier.Height, StandardStartedHeight: h.plan.Barrier.Height}
	raw, _ := json.Marshal(claim)
	digest := contract.PayloadDigest(raw)
	if h.corruptHandoffDigest {
		digest = strings.Repeat("0", 64)
	}
	return HandoffEvidence{RunID: claim.RunID, BindingDigest: claim.BindingDigest, RecoveryID: claim.RecoveryID, StandardID: claim.StandardID, RecoveryBinaryDigest: claim.RecoveryBinaryDigest, StandardBinaryDigest: claim.StandardBinaryDigest, RecoveryProcessedHeight: claim.RecoveryProcessedHeight, StandardStartedHeight: claim.StandardStartedHeight, RawSHA256: digest, Raw: raw}, nil
}
func (h *fakeHooks) ReadHPlusOne(_ context.Context, b contract.RunBinding, p isolation.PinnedResource) (HPlusOneEvidence, error) {
	h.events = append(h.events, "hplus1")
	if !h.standardReady || !h.docker.containers[p.ID].running {
		return HPlusOneEvidence{}, ErrPrecondition
	}
	digest := contract.PayloadDigest(h.hplusRaw)
	if h.corruptHPlusOneDigest {
		digest = strings.Repeat("0", 64)
	}
	return HPlusOneEvidence{RunID: b.RunID, BindingDigest: bindingDigest(b), RuntimeID: p.ID, RawSHA256: digest, Raw: h.hplusRaw}, nil
}

func driverFixture(t *testing.T, writeMarker bool) (*Coordinator, *fakeDocker, *fakeHooks, *memoryJournal, Plan, contract.RunBinding) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"source", "control", "evidence", "fork-a", "fork-b"} {
		if err := os.Mkdir(filepath.Join(root, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name string, data []byte, mode os.FileMode) string {
		p := filepath.Join(root, name)
		if err := os.WriteFile(p, data, mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	rec := write("recovery-binary", []byte("recovery bytes"), 0o500)
	orig := write("original-binary", []byte("original bytes"), 0o500)
	dig := func(p string) string {
		raw, e := os.ReadFile(p)
		if e != nil {
			t.Fatal(e)
		}
		return contract.PayloadDigest(raw)
	}
	h := int64(370)
	b := contract.RunBinding{SchemaVersion: contract.Version, RunID: "driver-run", Scenario: contract.Scenario, Workspace: root, OwnershipMarker: "owner-driver", ChainID: "driver-chain", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 370, App: 369, Consensus: &h, FirstRepaired: 370}, BlockID: strings.Repeat("b", 64), AppHash: strings.Repeat("c", 64), AppHashHeight: 369, ToolVersion: "test", CatalogVersion: "1", InputDigests: map[string]string{"source": strings.Repeat("d", 64), "recovery-binary": dig(rec), "original-binary": dig(orig)}, RuntimeIdentities: map[string]string{"runtime": "docker-test"}, Paths: map[string]string{"source": filepath.Join(root, "source"), "control": filepath.Join(root, "control"), "evidence": filepath.Join(root, "evidence"), "fork-a": filepath.Join(root, "fork-a"), "fork-b": filepath.Join(root, "fork-b"), "recovery-binary": rec, "original-binary": orig}}
	makeSpec := func(name, fork string, role isolation.BinaryRole) isolation.ContainerSpec {
		d := bindingDigest(b)
		return isolation.ContainerSpec{Name: name, Image: testImage, Argv: []string{"start", "--home", "/root/.inference"}, Mounts: []isolation.Mount{{PathKey: "source", Target: "/source", ReadOnly: true}, {PathKey: "control", Target: "/control", ReadOnly: true}, {PathKey: "evidence", Target: "/evidence", ReadOnly: true}, {PathKey: fork, Target: "/root/.inference", ReadOnly: false}, {PathKey: string(role) + "-binary", Target: "/root/gnklab0002/selected/inferenced", ReadOnly: true}}, Labels: map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": d}, Entrypoint: []string{"/root/gnklab0002/selected/inferenced"}, Environment: map[string]string{"GNK_LAB_SELECTED_BINARY_ROLE": string(role), "GNK_LAB_RECOVERY_BINARY_SHA256": b.InputDigests["recovery-binary"], "GNK_LAB_ORIGINAL_BINARY_SHA256": b.InputDigests["original-binary"], "GNK_LAB_RECOVERY_BARRIER_CHAIN_ID": b.ChainID, "GNK_LAB_RECOVERY_BARRIER_DIR": "/root/.inference/gnklab0002-recovery-barrier"}, ForkTarget: "/root/.inference", SelectedBinaryRole: role}
	}
	priorApp := strings.Repeat("c", 64)
	priorBlock := strings.Repeat("b", 64)
	priorPart := strings.Repeat("d", 64)
	barrier := coregate.BarrierMarkerExpectation{ChainID: b.ChainID, Height: 370, Stage: coregate.HandshakeReplay, AppHash: priorApp, BlockHash: priorBlock, PartSetTotal: 1, PartSetHash: priorPart}
	hplusRaw, plusBlock, plusPart := makeHPlusOne(t, b.ChainID, 370, priorBlock, priorPart, priorApp)
	hplus := coregate.HPlusOneExpectation{RunID: b.RunID, NodeID: "node-1", ChainID: b.ChainID, Height: 370, PreviousBlockID: priorBlock, PreviousPartSetHash: priorPart, PreviousPartSetTotal: 1, HeaderAppHash: priorApp, BlockID: plusBlock, PartSetHash: plusPart, PartSetTotal: 1}
	plan := Plan{Binding: b, NodeID: "node-1", ControlFailureKind: "expected-control-rejection", Control: makeSpec("control-old", "fork-b", isolation.BinaryOriginal), Recovery: makeSpec("recovery-node", "fork-a", isolation.BinaryRecovery), Standard: makeSpec("standard-node", "fork-a", isolation.BinaryOriginal), Barrier: barrier, HPlusOne: hplus, BlockPartSize: 1024, BarrierWait: 30 * time.Millisecond, PollInterval: time.Millisecond}
	if err := validatePlan(plan); err != nil {
		t.Fatalf("fixture plan invalid: binding=%v control=%v recovery=%v standard=%v barrier=%+v hplus=%+v", contract.ValidateBinding(b), plan.Control.ValidateBinding(b), plan.Recovery.ValidateBinding(b), plan.Standard.ValidateBinding(b), plan.Barrier, plan.HPlusOne)
	}
	docker := &fakeDocker{binding: b, plan: plan, containers: map[string]*testContainer{}, writeMarker: writeMarker}
	hooks := &fakeHooks{docker: docker, plan: plan, hplusRaw: hplusRaw}
	journal := newMemoryJournal(bindingDigest(b))
	runtime, err := isolation.NewRuntimeAdapter(docker, "/usr/bin/docker", b, journal)
	if err != nil {
		t.Fatal(err)
	}
	coordinator, err := newCoordinator(plan, runtime, docker, "/usr/bin/docker", journal, hooks)
	if err != nil {
		t.Fatal(err)
	}
	return coordinator, docker, hooks, journal, plan, b
}

func makeHPlusOne(t *testing.T, chain string, height int64, priorBlock, priorPart, appHash string) ([]byte, string, string) {
	t.Helper()
	decode := func(s string) []byte {
		b, e := hex.DecodeString(s)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	prior := tmtypes.BlockID{Hash: cmtbytes.HexBytes(decode(priorBlock)), PartSetHeader: tmtypes.PartSetHeader{Total: 1, Hash: cmtbytes.HexBytes(decode(priorPart))}}
	lastCommit := &tmtypes.Commit{Height: height, BlockID: prior, Signatures: []tmtypes.CommitSig{{BlockIDFlag: tmtypes.BlockIDFlagAbsent}}}
	block := tmtypes.MakeBlock(height+1, nil, lastCommit, nil)
	block.Header.ChainID = chain
	block.Header.Time = time.Unix(1_800_000_005, 0).UTC()
	block.Header.LastBlockID = prior
	block.Header.AppHash = decode(appHash)
	block.Header.ValidatorsHash = bytes.Repeat([]byte{0x11}, 32)
	block.Header.NextValidatorsHash = bytes.Repeat([]byte{0x11}, 32)
	block.Header.ConsensusHash = bytes.Repeat([]byte{0x22}, 32)
	block.Header.LastResultsHash = bytes.Repeat([]byte{0x44}, 32)
	block.Header.ProposerAddress = tmtypes.Address(bytes.Repeat([]byte{0x33}, 20))
	if err := block.ValidateBasic(); err != nil {
		t.Fatalf("construct H+1 block: %v", err)
	}
	part, err := block.MakePartSet(1024)
	if err != nil {
		t.Fatal(err)
	}
	protoBlock, err := block.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := proto.Marshal(protoBlock)
	if err != nil {
		t.Fatal(err)
	}
	return raw, hex.EncodeToString(block.Hash()), hex.EncodeToString(part.Header().Hash)
}
func bindingDigest(b contract.RunBinding) string { d, _ := contract.Digest(b); return d }

func TestCoordinatorOrdersControlRecoveryOfflineHandoffAndHPlusOne(t *testing.T) {
	c, d, h, j, _, _ := driverFixture(t, true)
	result, err := c.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.ControlPin.ID == "" || result.RecoveryPin.ID == "" || result.StandardPin.ID == "" || result.Barrier.Height != 370 || result.HPlusOne.Block.Height != 371 {
		t.Fatalf("incomplete result: %+v", result)
	}
	ledger, err := j.Read(context.Background(), j.ledger.BindingDigest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ledger.Completed) != len(orderedSteps) {
		t.Fatalf("recorded %d steps", len(ledger.Completed))
	}
	for i, s := range orderedSteps {
		if ledger.Completed[i].Step != s {
			t.Fatalf("step[%d]=%s want %s", i, ledger.Completed[i].Step, s)
		}
	}
	if !h.standardReady || len(h.events) < 3 || h.events[len(h.events)-1] != "hplus1" {
		t.Fatalf("hook order: %v", h.events)
	}
	pos := func(w string) int {
		for i, x := range d.ops {
			if x == w {
				return i
			}
		}
		return -1
	}
	if pos("start:control-old") < 0 || pos("start:recovery-node") <= pos("start:control-old") || pos("kill:recovery-node") <= pos("start:recovery-node") || pos("start:standard-node") <= pos("kill:recovery-node") {
		t.Fatalf("runtime order: %v", d.ops)
	}
}

func TestCoordinatorStagePrefixThenRunResumesWithoutRepeatingControl(t *testing.T) {
	c, d, _, j, _, _ := driverFixture(t, true)
	if err := c.RunThrough(context.Background(), ControlStop); err != nil {
		t.Fatalf("control stage prefix: %v", err)
	}
	ledger, err := j.Read(context.Background(), j.ledger.BindingDigest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ledger.Completed) != 4 || ledger.Completed[3].Step != ControlStop {
		t.Fatalf("unexpected stage ledger: %+v", ledger.Completed)
	}
	if _, err := c.Run(context.Background()); err != nil {
		t.Fatalf("resume full run: %v", err)
	}
	controlStarts := 0
	for _, op := range d.ops {
		if op == "start:control-old" {
			controlStarts++
		}
	}
	if controlStarts != 1 {
		t.Fatalf("control replayed on run resume: %v", d.ops)
	}
	ledger, err = j.Read(context.Background(), j.ledger.BindingDigest)
	if err != nil || len(ledger.Completed) != len(orderedSteps) {
		t.Fatalf("incomplete resumed ledger: %+v %v", ledger, err)
	}
}

func TestCoordinatorMissingFreshBarrierNeverKills(t *testing.T) {
	c, d, _, j, _, _ := driverFixture(t, false)
	_, err := c.Run(context.Background())
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("missing barrier should pause phase: %v", err)
	}
	if strings.Contains(strings.Join(d.ops, ","), "kill:recovery-node") {
		t.Fatalf("killed without barrier: %v", d.ops)
	}
	ledger, _ := j.Read(context.Background(), j.ledger.BindingDigest)
	if len(ledger.Completed) != 7 || ledger.Completed[6].Step != RecoveryStart {
		t.Fatalf("unexpected pause point: %+v", ledger.Completed)
	}
}

func TestChangedRecoveryBinaryCannotLaunchAndOutcomeIsQuarantined(t *testing.T) {
	c, d, h, j, _, _ := driverFixture(t, true)
	h.mutateRecoveryBinary = true
	_, err := c.Run(context.Background())
	if !errors.Is(err, ErrUnknown) {
		t.Fatalf("substituted recovery bytes not quarantined: %v", err)
	}
	for _, op := range d.ops {
		if op == "create:recovery-node" || op == "start:recovery-node" || op == "kill:recovery-node" {
			t.Fatalf("substituted binary reached recovery operation: %v", d.ops)
		}
	}
	ledger, _ := j.Read(context.Background(), j.ledger.BindingDigest)
	if !ledger.Unknown {
		t.Fatal("uncertain mutation intent not persisted unknown")
	}
}

func TestMissingOfflineReaderPausesAfterKillAndResumesWithoutRekill(t *testing.T) {
	c, d, hooks, _, _, _ := driverFixture(t, true)
	hooks.offlineUnavailable = true
	if _, err := c.Run(context.Background()); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("missing offline reader was not a phase pause: %v", err)
	}
	kills := func() int {
		n := 0
		for _, op := range d.ops {
			if op == "kill:recovery-node" {
				n++
			}
		}
		return n
	}
	if kills() != 1 {
		t.Fatalf("expected one durable hard-stop, got %d (%v)", kills(), d.ops)
	}
	hooks.offlineUnavailable = false
	if _, err := c.Run(context.Background()); err != nil {
		t.Fatalf("resume at offline-store phase: %v", err)
	}
	if kills() != 1 {
		t.Fatalf("resume repeated repair kill: %d (%v)", kills(), d.ops)
	}
}

func TestProductionConstructorRejectsMissingJournalBeforeRuntimeCreation(t *testing.T) {
	_, _, hooks, _, plan, _ := driverFixture(t, true)
	if _, err := NewDockerCoordinator(plan, "/usr/bin/docker", nil, hooks); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("missing journal should fail before runtime use: %v", err)
	}
}

func TestPendingIntentAndFailedCompletionDoNotRepeatCreate(t *testing.T) {
	t.Run("pending", func(t *testing.T) {
		c, d, _, j, _, _ := driverFixture(t, true)
		p := ControlCreate
		j.pending = &p
		if _, err := c.Run(context.Background()); !errors.Is(err, ErrUnknown) {
			t.Fatalf("pending intent accepted: %v", err)
		}
		if len(d.ops) != 0 {
			t.Fatalf("runtime called despite pending intent: %v", d.ops)
		}
	})
	t.Run("completion failure", func(t *testing.T) {
		c, d, _, j, _, _ := driverFixture(t, true)
		j.failComplete = ControlCreate
		if _, err := c.Run(context.Background()); !errors.Is(err, ErrUnknown) {
			t.Fatalf("completion failure not unknown: %v", err)
		}
		n := len(d.ops)
		if _, err := c.Run(context.Background()); !errors.Is(err, ErrUnknown) || len(d.ops) != n {
			t.Fatalf("control create retried: %v %v", err, d.ops)
		}
	})
}

func TestPlanRequiresDistinctControlForkAndPinnedRoles(t *testing.T) {
	_, _, _, _, p, _ := driverFixture(t, true)
	q := p
	q.Standard.SelectedBinaryRole = isolation.BinaryRecovery
	if validatePlan(q) == nil {
		t.Fatal("accepted recovery binary for standard handoff")
	}
	q = p
	q.Recovery.SelectedBinaryRole = isolation.BinaryOriginal
	if validatePlan(q) == nil {
		t.Fatal("accepted original binary for recovery")
	}
	q = p
	q.Control.Mounts[3].PathKey = "fork-a"
	if validatePlan(q) == nil {
		t.Fatal("accepted shared control/recovery fork")
	}
}

func TestEvidenceRawDigestMismatchIsRejected(t *testing.T) {
	t.Run("handoff", func(t *testing.T) {
		c, _, hooks, _, _, _ := driverFixture(t, true)
		hooks.corruptHandoffDigest = true
		if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) {
			t.Fatalf("handoff digest mismatch was accepted: %v", err)
		}
	})
	t.Run("H+1", func(t *testing.T) {
		c, _, hooks, _, _, _ := driverFixture(t, true)
		hooks.corruptHPlusOneDigest = true
		if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) {
			t.Fatalf("H+1 digest mismatch was accepted: %v", err)
		}
	})
}
