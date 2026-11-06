//go:build linux

package incidenthost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testOriginalID = "1111111111111111111111111111111111111111111111111111111111111111"
	testImageID    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testRecoveryID = "2222222222222222222222222222222222222222222222222222222222222222"
)

type fixture struct {
	target Target
	deps   hostDeps
	docker *mockDocker
	paths  hostPaths
}

func newFixture(t *testing.T) fixture {
	return newFixtureLayout(t, false)
}

func newFixtureLayout(t *testing.T, symlinkDataRoot bool) fixture {
	t.Helper()
	root := t.TempDir()
	paths := hostPaths{
		dataMount:      filepath.Join(root, "inference"),
		dataRoot:       filepath.Join(root, "inference", "data"),
		originalBinary: filepath.Join(root, "inference", "inferenced"),
		recoveryRoot:   filepath.Join(root, "recovery"),
		identityDir:    filepath.Join(root, "identity"),
		genesisFile:    filepath.Join(root, "genesis.json"),
		procRoot:       filepath.Join(root, "proc"),
		rpcAddress:     "",
	}
	actualDataRoot := paths.dataRoot
	if symlinkDataRoot {
		actualDataRoot = filepath.Join(root, "external-data")
	}
	if err := os.MkdirAll(paths.dataMount, 0700); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{actualDataRoot, paths.identityDir, paths.procRoot, filepath.Join(paths.procRoot, "100", "fd")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if symlinkDataRoot {
		if err := os.Symlink(actualDataRoot, paths.dataRoot); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(paths.procRoot, "100", "comm"), []byte("bash\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.genesisFile, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	binary := []byte("test original inferenced binary")
	if err := os.WriteFile(paths.originalBinary, binary, 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(binary)
	original := dockerContainer{ID: testOriginalID, Image: testImageID, Name: "/inferenced"}
	original.Config.Image = testImageID
	original.Config.Entrypoint = nil
	original.State.Status = "running"
	original.State.Running = true
	original.State.Pid = 42
	original.Mounts = append(original.Mounts, struct {
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Type        string `json:"Type"`
		RW          bool   `json:"RW"`
	}{Source: paths.dataMount, Destination: "/root/.inference", Type: "bind", RW: true})
	docker := &mockDocker{containers: map[string]dockerContainer{testOriginalID: original}, image: dockerImage{ID: recoveryImageID}}
	target := Target{
		Original:   testOriginalID,
		Image:      testImageID,
		Entrypoint: "null",
		Consumers:  strings.Repeat("3", 64) + "|" + strings.Repeat("4", 64),
	}
	return fixture{target: target, deps: hostDeps{docker: docker, fs: osFS{}, paths: paths, binHash: hex.EncodeToString(digest[:]), rpcCheck: func(context.Context) error { return nil }}, docker: docker, paths: paths}
}

type mockDocker struct {
	containers        map[string]dockerContainer
	image             dockerImage
	consumers         []dockerSummary
	calls             []string
	created           dockerCreate
	createName        string
	killed            int
	inspectCounts     map[string]int
	inspectHook       func(string, int)
	failRecoveryStart bool
}

func (m *mockDocker) inspect(_ context.Context, ref string) (dockerContainer, error) {
	m.calls = append(m.calls, "inspect:"+ref)
	if m.inspectCounts == nil {
		m.inspectCounts = map[string]int{}
	}
	m.inspectCounts[ref]++
	if m.inspectHook != nil {
		m.inspectHook(ref, m.inspectCounts[ref])
	}
	if c, ok := m.containers[ref]; ok {
		return c, nil
	}
	for _, c := range m.containers {
		if c.Name == "/"+ref {
			return c, nil
		}
	}
	return dockerContainer{}, &dockerHTTPError{status: http.StatusNotFound, message: "missing"}
}

func (m *mockDocker) listVolumeConsumers(context.Context, string) ([]dockerSummary, error) {
	m.calls = append(m.calls, "list-consumers")
	return m.consumers, nil
}

func (m *mockDocker) inspectImage(context.Context, string) (dockerImage, error) {
	m.calls = append(m.calls, "inspect-image")
	return m.image, nil
}

func (m *mockDocker) stop(_ context.Context, id string, _ int) error {
	m.calls = append(m.calls, "stop")
	c := m.containers[id]
	c.State.Running, c.State.Status, c.State.Pid = false, "exited", 0
	m.containers[id] = c
	return nil
}

func (m *mockDocker) create(_ context.Context, name string, spec dockerCreate) (string, error) {
	m.calls = append(m.calls, "create")
	m.created, m.createName = spec, name
	c := dockerContainer{ID: testRecoveryID, Image: recoveryImageID, Name: "/" + name}
	c.Config.Image = spec.createConfig.Image
	c.Config.Entrypoint = spec.createConfig.Entrypoint
	c.Config.Cmd = spec.createConfig.Cmd
	c.Config.Env = spec.createConfig.Env
	c.Config.Labels = spec.createConfig.Labels
	c.Config.Hostname = "incident-host"
	c.HostConfig.NetworkMode = spec.HostConfig.NetworkMode
	c.HostConfig.RestartPolicy.Name = spec.HostConfig.RestartPolicy.Name
	for _, mount := range spec.HostConfig.Mounts {
		c.Mounts = append(c.Mounts, struct {
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
			Type        string `json:"Type"`
			RW          bool   `json:"RW"`
		}{Source: mount.Source, Destination: mount.Target, Type: mount.Type, RW: !mount.ReadOnly})
	}
	for name, endpoint := range spec.NetworkingConfig.EndpointsConfig {
		c.NetworkSettings.Networks = map[string]struct {
			Aliases []string `json:"Aliases"`
		}{name: {Aliases: endpoint.Aliases}}
	}
	c.State.Status = "created"
	m.containers[testRecoveryID] = c
	return c.ID, nil
}

func (m *mockDocker) start(_ context.Context, id string) error {
	m.calls = append(m.calls, "start:"+id)
	if m.failRecoveryStart && id == testRecoveryID {
		return nil
	}
	c := m.containers[id]
	c.State.Running, c.State.Status, c.State.Pid = true, "running", 99
	m.containers[id] = c
	return nil
}

func (m *mockDocker) kill(_ context.Context, id, signal string) error {
	m.calls = append(m.calls, "kill:"+signal)
	m.killed++
	c := m.containers[id]
	c.State.Running, c.State.Status, c.State.Pid, c.State.ExitCode = false, "exited", 0, 137
	m.containers[id] = c
	return nil
}

func (m *mockDocker) logs(context.Context, string, int) (string, error) {
	m.calls = append(m.calls, "logs")
	return "bounded test log", nil
}

func TestRepairUsesPinnedPreconditionsAndOrderedOperations(t *testing.T) {
	f := newFixture(t)
	got, err := runWith(context.Background(), "node11", "repair", f.target, f.deps)
	if err != nil {
		t.Fatal(err)
	}
	result := got.(Result)
	if result.Original.Running || result.Recovery == nil || !result.Recovery.Running {
		t.Fatalf("unexpected result: %+v", result)
	}
	stop, create, start := indexCall(f.docker.calls, "stop"), indexCall(f.docker.calls, "create"), indexCall(f.docker.calls, "start:"+testRecoveryID)
	if stop < 0 || create <= stop || start <= create {
		t.Fatalf("operation order is unsafe: %v", f.docker.calls)
	}
	if f.docker.createName != "gnklab0002-node11-bcb9de867" || f.docker.created.HostConfig.NetworkMode != "gdc-node11_default" {
		t.Fatalf("unexpected recovery identity/network: %s %+v", f.docker.createName, f.docker.created.HostConfig)
	}
	if !hasEnv(f.docker.created.createConfig.Env, "GNK_LAB_RECOVERY_BARRIER_DIR=/barrier") {
		t.Fatal("missing barrier environment")
	}
}

func TestRepairRejectsWrongOriginalImageBeforeMutation(t *testing.T) {
	f := newFixture(t)
	f.target.Image = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	_, err := runWith(context.Background(), "node11", "repair", f.target, f.deps)
	if err == nil || !strings.Contains(err.Error(), "image ID differs") {
		t.Fatalf("expected pinned image rejection, got %v", err)
	}
	for _, call := range f.docker.calls {
		if call == "stop" || call == "create" || strings.HasPrefix(call, "start:") || strings.HasPrefix(call, "kill:") {
			t.Fatalf("mutation happened before pin validation: %v", f.docker.calls)
		}
	}
	if _, err := os.Stat(f.paths.recoveryRoot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("wrong pin created recovery state before validation: stat error=%v", err)
	}
}

func TestHaltRejectsBarrierMismatchWithoutKilling(t *testing.T) {
	f := newFixture(t)
	f.installRecovery(t, true)
	if err := os.MkdirAll(filepath.Join(f.paths.recoveryRoot, "barrier"), 0700); err != nil {
		t.Fatal(err)
	}
	barrier := expectedBarrier("incident-host")
	barrier.AppHash = strings.Repeat("0", 64)
	data, _ := json.Marshal(barrier)
	if err := os.WriteFile(filepath.Join(f.paths.recoveryRoot, "barrier", barrierFile), data, 0600); err != nil {
		t.Fatal(err)
	}
	_, err := runWith(context.Background(), "node11", "halt", f.target, f.deps)
	if err == nil || !strings.Contains(err.Error(), "replay barrier") {
		t.Fatalf("expected barrier mismatch error, got %v", err)
	}
	if f.docker.killed != 0 {
		t.Fatal("recovery container was killed despite a mismatched barrier")
	}
}

func TestHaltAndResumeRequireBarrierAndPreserveOrder(t *testing.T) {
	f := newFixture(t)
	f.installRecovery(t, true)
	if err := os.MkdirAll(filepath.Join(f.paths.recoveryRoot, "barrier"), 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(expectedBarrier("incident-host"))
	if err := os.WriteFile(filepath.Join(f.paths.recoveryRoot, "barrier", barrierFile), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := runWith(context.Background(), "node11", "halt", f.target, f.deps); err != nil {
		t.Fatal(err)
	}
	if f.docker.killed != 1 {
		t.Fatal("halt did not send exactly one SIGKILL")
	}
	if _, err := runWith(context.Background(), "node11", "resume", f.target, f.deps); err != nil {
		t.Fatal(err)
	}
	if !f.docker.containers[testOriginalID].State.Running {
		t.Fatal("resume did not start original container")
	}
	kill, start := indexCall(f.docker.calls, "kill:KILL"), indexCall(f.docker.calls, "start:"+testOriginalID)
	if kill < 0 || start <= kill {
		t.Fatalf("unsafe halt/resume order: %v", f.docker.calls)
	}
}

func TestLifecycleWorksWithFlatAndSymlinkDataRoots(t *testing.T) {
	for _, layout := range []struct {
		name    string
		symlink bool
	}{{name: "flat"}, {name: "symlink", symlink: true}} {
		t.Run(layout.name, func(t *testing.T) {
			f := newFixtureLayout(t, layout.symlink)
			if _, err := runWith(context.Background(), "node11", "status", f.target, f.deps); err != nil {
				t.Fatalf("initial status: %v", err)
			}
			if _, err := runWith(context.Background(), "node11", "repair", f.target, f.deps); err != nil {
				t.Fatalf("repair: %v", err)
			}
			if err := os.MkdirAll(filepath.Join(f.paths.recoveryRoot, "barrier"), 0700); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(expectedBarrier("incident-host"))
			if err := os.WriteFile(filepath.Join(f.paths.recoveryRoot, "barrier", barrierFile), data, 0600); err != nil {
				t.Fatal(err)
			}
			status, err := runWith(context.Background(), "node11", "status", f.target, f.deps)
			if err != nil {
				t.Fatalf("barrier status: %v", err)
			}
			if got := status.(Result); len(got.Barrier) == 0 || got.Logs != "bounded test log" {
				t.Fatalf("status did not return validated barrier and bounded logs: %+v", got)
			}
			if _, err := runWith(context.Background(), "node11", "halt", f.target, f.deps); err != nil {
				t.Fatalf("halt: %v", err)
			}
			if _, err := runWith(context.Background(), "node11", "resume", f.target, f.deps); err != nil {
				t.Fatalf("resume: %v", err)
			}
		})
	}
}

func TestLaunchStartsOnlyWithStoppedOriginalAndEmptyBarrier(t *testing.T) {
	for _, layout := range []struct {
		name    string
		symlink bool
	}{{name: "flat"}, {name: "symlink", symlink: true}} {
		t.Run(layout.name, func(t *testing.T) {
			f := newFixtureLayout(t, layout.symlink)
			original := f.docker.containers[testOriginalID]
			original.State.Status, original.State.Running, original.State.Pid = "exited", false, 0
			f.docker.containers[testOriginalID] = original
			if err := os.MkdirAll(filepath.Join(f.paths.recoveryRoot, "barrier"), 0700); err != nil {
				t.Fatal(err)
			}
			if _, err := runWith(context.Background(), "node11", "launch", f.target, f.deps); err != nil {
				t.Fatal(err)
			}
			if !f.docker.containers[testRecoveryID].State.Running {
				t.Fatal("launch did not start the pinned recovery container")
			}
		})
	}
}

func TestCheckProcessesRejectsOpenDataDescriptor(t *testing.T) {
	f := newFixture(t)
	fdDir := filepath.Join(f.paths.procRoot, "100", "fd")
	if err := os.Symlink(filepath.Join(f.paths.dataRoot, "application.db"), filepath.Join(fdDir, "7")); err != nil {
		t.Fatal(err)
	}
	h := host{node: "node11", target: f.target, docker: f.docker, fs: f.deps.fs, paths: f.paths}
	if err := h.checkProcesses(); err == nil || !strings.Contains(err.Error(), "descriptor remains open") {
		t.Fatalf("expected open chain DB descriptor rejection, got %v", err)
	}
}

func TestFilteredConsumerWithResolvedMountPathStillRejectsUnknownID(t *testing.T) {
	f := newFixture(t)
	original := f.docker.containers[testOriginalID]
	original.State.Running = false
	f.docker.containers[testOriginalID] = original
	f.docker.consumers = []dockerSummary{{ID: strings.Repeat("9", 64), State: "running", Mounts: []struct {
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Type        string `json:"Type"`
	}{{Source: "/resolved/inference", Destination: "/root/.inference", Type: "bind"}}}}
	h := host{node: "node11", target: f.target, docker: f.docker, fs: f.deps.fs, paths: f.paths}
	if err := h.checkNoChainWriter(context.Background()); err == nil || !strings.Contains(err.Error(), "unexpected running") {
		t.Fatalf("unexpected filtered consumer was accepted: %v", err)
	}
}

func TestProcessPermissionErrorsFailClosed(t *testing.T) {
	f := newFixture(t)
	h := host{node: "node11", target: f.target, docker: f.docker, fs: deniedProcFS{hostFS: osFS{}, denied: filepath.Join(f.paths.procRoot, "100", "fd")}, paths: f.paths}
	if err := h.checkProcesses(); err == nil || !strings.Contains(err.Error(), "inspect process 100 descriptors") {
		t.Fatalf("inaccessible process descriptors were treated as clean: %v", err)
	}
}

func TestRecoveryIdentityRequiresFullID(t *testing.T) {
	f := newFixture(t)
	f.installRecovery(t, true)
	c := f.docker.containers[testRecoveryID]
	c.ID = "short"
	f.docker.containers[testRecoveryID] = c
	if err := os.MkdirAll(filepath.Join(f.paths.recoveryRoot, "barrier"), 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(expectedBarrier("incident-host"))
	if err := os.WriteFile(filepath.Join(f.paths.recoveryRoot, "barrier", barrierFile), data, 0600); err != nil {
		t.Fatal(err)
	}
	_, err := runWith(context.Background(), "node11", "halt", f.target, f.deps)
	if err == nil || !strings.Contains(err.Error(), "image identity") {
		t.Fatalf("short recovery ID was accepted: %v", err)
	}
	if f.docker.killed != 0 {
		t.Fatal("container was killed with an invalid identity")
	}
}

func TestOriginalMountIsRecheckedUnderLockBeforeMutation(t *testing.T) {
	f := newFixture(t)
	f.docker.inspectHook = func(ref string, count int) {
		if ref == testOriginalID && count == 2 {
			c := f.docker.containers[testOriginalID]
			c.Mounts[0].Source = "/unexpected/resolved/path"
			f.docker.containers[testOriginalID] = c
		}
	}
	_, err := runWith(context.Background(), "node11", "repair", f.target, f.deps)
	if err == nil || !strings.Contains(err.Error(), "pinned inference-data mount") {
		t.Fatalf("changed original mount was not rejected under lock: %v", err)
	}
	for _, call := range f.docker.calls {
		if call == "stop" || call == "create" || strings.HasPrefix(call, "start:") {
			t.Fatalf("mutated before rechecking original mount: %v", f.docker.calls)
		}
	}
}

func TestOriginalBinaryIsRecheckedUnderLockBeforeMutation(t *testing.T) {
	f := newFixture(t)
	f.deps.fs = &flippingBinaryFS{hostFS: osFS{}, path: f.paths.originalBinary}
	_, err := runWith(context.Background(), "node11", "repair", f.target, f.deps)
	if err == nil || !strings.Contains(err.Error(), "binary hash differs") {
		t.Fatalf("changed original binary was not rejected under lock: %v", err)
	}
	for _, call := range f.docker.calls {
		if call == "stop" || call == "create" || strings.HasPrefix(call, "start:") {
			t.Fatalf("mutated before rechecking original binary: %v", f.docker.calls)
		}
	}
}

func TestDockerCreateRequestUsesNativeAPIShape(t *testing.T) {
	encoded, err := json.Marshal(dockerCreate{
		createConfig: createConfig{Image: recoveryImageID, Entrypoint: []string{"/usr/bin/inferenced"}},
		HostConfig:   createHostConfig{NetworkMode: "gdc-node11_default"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &object); err != nil {
		t.Fatal(err)
	}
	if _, ok := object["Image"]; !ok {
		t.Fatalf("container config was not flattened into Docker create JSON: %s", encoded)
	}
	if _, ok := object["HostConfig"]; !ok {
		t.Fatalf("Docker HostConfig field missing: %s", encoded)
	}
	if _, nested := object["config"]; nested {
		t.Fatalf("unexpected nested config object: %s", encoded)
	}
}

func TestDockerClientNegotiatesSupportedVersionAndVolumeFilter(t *testing.T) {
	var apiPath string
	transport := roundTripFunc(func(req *http.Request) (*http.Response, error) {
		apiPath = req.URL.Path
		body := "[]"
		if req.URL.Path == "/version" {
			body = `{"ApiVersion":"1.56","MinAPIVersion":"1.24"}`
		} else {
			if req.URL.Path != "/v1.41/containers/json" {
				t.Errorf("unexpected Docker path %s", req.URL.String())
			}
			filters := req.URL.Query().Get("filters")
			var decoded map[string][]string
			if err := json.Unmarshal([]byte(filters), &decoded); err != nil || len(decoded["volume"]) != 1 || decoded["volume"][0] != "/srv/dai/data/inference" {
				t.Errorf("unexpected volume filter %q, decode error=%v", filters, err)
			}
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), Request: req}, nil
	})
	docker := &unixDocker{client: &http.Client{Transport: transport}}
	if _, err := docker.listVolumeConsumers(context.Background(), "/srv/dai/data/inference"); err != nil {
		t.Fatal(err)
	}
	if docker.apiVersion != "1.41" || apiPath != "/v1.41/containers/json" {
		t.Fatalf("Docker API version was not negotiated: version=%q final path=%q", docker.apiVersion, apiPath)
	}
}

func TestRecoveryStartMustActuallyRun(t *testing.T) {
	f := newFixture(t)
	f.docker.failRecoveryStart = true
	if _, err := runWith(context.Background(), "node11", "repair", f.target, f.deps); err == nil || !strings.Contains(err.Error(), "did not enter running state") {
		t.Fatalf("non-running recovery was reported successful: %v", err)
	}
}

func (f fixture) installRecovery(t *testing.T, running bool) {
	t.Helper()
	c := dockerContainer{ID: testRecoveryID, Image: recoveryImageID, Name: "/gnklab0002-node11-bcb9de867"}
	c.Config.Image = recoveryImageID
	c.Config.Entrypoint = []string{"/usr/bin/inferenced"}
	c.Config.Cmd = []string{"start", "--home", "/root/.inference", "--priv_validator_laddr", "tcp://0.0.0.0:26658", "--p2p.pex=false"}
	c.Config.Env = []string{"GNK_LAB_RECOVERY_BARRIER_CHAIN_ID=" + chainID, "GNK_LAB_RECOVERY_BARRIER_DIR=/barrier"}
	c.Config.Labels = map[string]string{"gnklab.incident": incidentLabel}
	c.Config.Hostname = "incident-host"
	c.HostConfig.NetworkMode = "gdc-node11_default"
	c.HostConfig.RestartPolicy.Name = "no"
	c.NetworkSettings.Networks = map[string]struct {
		Aliases []string `json:"Aliases"`
	}{"gdc-node11_default": {Aliases: []string{"node"}}}
	for _, m := range []dockerMount{
		{Type: "bind", Source: f.paths.dataMount, Target: "/root/.inference"},
		{Type: "bind", Source: f.paths.identityDir, Target: "/gdc-identity", ReadOnly: true},
		{Type: "bind", Source: f.paths.genesisFile, Target: "/root/genesis.json", ReadOnly: true},
		{Type: "bind", Source: filepath.Join(f.paths.recoveryRoot, "barrier"), Target: "/barrier"},
	} {
		c.Mounts = append(c.Mounts, struct {
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
			Type        string `json:"Type"`
			RW          bool   `json:"RW"`
		}{Source: m.Source, Destination: m.Target, Type: m.Type, RW: !m.ReadOnly})
	}
	c.State.Status, c.State.Running, c.State.Pid = "running", running, 99
	if !running {
		c.State.Status, c.State.Pid = "exited", 0
	}
	f.docker.containers[testRecoveryID] = c
	original := f.docker.containers[testOriginalID]
	original.State.Status, original.State.Running, original.State.Pid = "exited", false, 0
	f.docker.containers[testOriginalID] = original
	if err := os.MkdirAll(f.paths.recoveryRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.paths.recoveryRoot, "controller.lock"), nil, 0600); err != nil {
		t.Fatal(err)
	}
}

func expectedBarrier(hostname string) barrierRecord {
	return barrierRecord{ChainID: chainID, Height: 814730, Stage: "handshake-replay", PID: 1,
		Hostname: hostname, BlockID: barrierBlockID, AppHash: barrierAppHash}
}

func indexCall(calls []string, want string) int {
	for i, call := range calls {
		if call == want {
			return i
		}
	}
	return -1
}

type deniedProcFS struct {
	hostFS
	denied string
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

type flippingBinaryFS struct {
	hostFS
	path  string
	count int
}

func (f *flippingBinaryFS) openFile(path string, flags int, mode os.FileMode) (*os.File, error) {
	if path == f.path {
		f.count++
		if f.count == 2 {
			if err := os.WriteFile(path, []byte("changed binary"), 0600); err != nil {
				return nil, err
			}
		}
	}
	return f.hostFS.openFile(path, flags, mode)
}

func (f deniedProcFS) readDir(path string) ([]os.DirEntry, error) {
	if path == f.denied {
		return nil, os.ErrPermission
	}
	return f.hostFS.readDir(path)
}
