//go:build linux

package incidenthost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

type hostFS interface {
	readFile(string) ([]byte, error)
	evalSymlinks(string) (string, error)
	mkdirAll(string, os.FileMode) error
	mkdir(string, os.FileMode) error
	readDir(string) ([]os.DirEntry, error)
	readlink(string) (string, error)
	openFile(string, int, os.FileMode) (*os.File, error)
}

type osFS struct{}

func (osFS) readFile(p string) ([]byte, error)                         { return os.ReadFile(p) }
func (osFS) evalSymlinks(p string) (string, error)                     { return filepath.EvalSymlinks(p) }
func (osFS) mkdirAll(p string, m os.FileMode) error                    { return os.MkdirAll(p, m) }
func (osFS) mkdir(p string, m os.FileMode) error                       { return os.Mkdir(p, m) }
func (osFS) readDir(p string) ([]os.DirEntry, error)                   { return os.ReadDir(p) }
func (osFS) readlink(p string) (string, error)                         { return os.Readlink(p) }
func (osFS) openFile(p string, f int, m os.FileMode) (*os.File, error) { return os.OpenFile(p, f, m) }

type hostPaths struct {
	dataMount      string
	dataRoot       string
	originalBinary string
	recoveryRoot   string
	identityDir    string
	genesisFile    string
	procRoot       string
	rpcAddress     string
}

func productionPaths() hostPaths {
	return hostPaths{
		dataMount: dataMount, dataRoot: dataRoot, originalBinary: originalBinary,
		recoveryRoot: recoveryRoot, identityDir: identityDir, genesisFile: genesisFile,
		procRoot: "/proc", rpcAddress: "http://127.0.0.1:26657/abci_info",
	}
}

type hostDeps struct {
	docker   dockerAPI
	fs       hostFS
	paths    hostPaths
	binHash  string
	rpcCheck func(context.Context) error
}

func runLinux(ctx context.Context, node, phase string, target Target) (any, error) {
	return runWith(ctx, node, phase, target, hostDeps{
		docker: newUnixDocker("/var/run/docker.sock"), fs: osFS{}, paths: productionPaths(), binHash: originalBinHash,
	})
}

func runWith(ctx context.Context, node, phase string, target Target, d hostDeps) (any, error) {
	if d.docker == nil || d.fs == nil {
		return nil, errors.New("incidenthost: incomplete host dependencies")
	}
	if d.binHash == "" {
		d.binHash = originalBinHash
	}
	h := host{node: node, target: target, docker: d.docker, fs: d.fs, paths: d.paths, binHash: d.binHash, rpcCheck: d.rpcCheck}
	var result Result
	var err error
	switch phase {
	case "status":
		result, err = h.status(ctx)
	case "repair":
		result, err = h.repair(ctx)
	case "launch":
		result, err = h.launch(ctx)
	case "halt":
		result, err = h.halt(ctx)
	case "resume":
		result, err = h.resume(ctx)
	}
	if err != nil {
		return nil, fmt.Errorf("incidenthost %s %s: %w", node, phase, err)
	}
	result.Node, result.Phase = node, phase
	return result, nil
}

type host struct {
	node     string
	target   Target
	docker   dockerAPI
	fs       hostFS
	paths    hostPaths
	binHash  string
	rpcCheck func(context.Context) error
}

func (h host) recoveryName() string { return fmt.Sprintf(recoveryName, h.node) }
func (h host) network() string      { return "gdc-" + h.node + "_default" }
func (h host) barrierPath() string {
	return filepath.Join(h.paths.recoveryRoot, "barrier", barrierFile)
}

func (h host) status(ctx context.Context) (Result, error) {
	original, err := h.inspectOriginal(ctx)
	if err != nil {
		return Result{}, err
	}
	result := Result{Original: stateOf(original)}
	recovery, err := h.inspectOptionalRecovery(ctx)
	if err != nil {
		return Result{}, err
	}
	if recovery == nil {
		return result, nil
	}
	if err := h.verifyRecovery(*recovery); err != nil {
		return Result{}, err
	}
	state := stateOf(*recovery)
	result.Recovery = &state
	if data, readErr := h.fs.readFile(h.barrierPath()); readErr == nil {
		barrier, checkErr := h.checkBarrier(*recovery, data)
		if checkErr != nil {
			return Result{}, checkErr
		}
		result.Barrier = barrier
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return Result{}, fmt.Errorf("read replay barrier: %w", readErr)
	}
	logs, err := h.docker.logs(ctx, recovery.ID, 100)
	if err != nil {
		return Result{}, fmt.Errorf("read bounded recovery logs: %w", err)
	}
	result.Logs = logs
	return result, nil
}

func (h host) repair(ctx context.Context) (Result, error) {
	original, err := h.inspectOriginal(ctx)
	if err != nil {
		return Result{}, err
	}
	if !original.State.Running {
		return Result{}, errors.New("original container is not running; inspect state instead of repeating repair")
	}
	if err := h.verifyOriginalMounts(original); err != nil {
		return Result{}, err
	}
	if err := h.checkOriginalBinary(); err != nil {
		return Result{}, err
	}
	if err := h.checkPreABCI(ctx); err != nil {
		return Result{}, err
	}
	img, err := h.docker.inspectImage(ctx, recoveryImageID)
	if err != nil {
		return Result{}, fmt.Errorf("inspect pinned recovery image: %w", err)
	}
	if img.ID != recoveryImageID {
		return Result{}, errors.New("recovery image ID differs from incident pin")
	}
	return h.withLock(true, func() (Result, error) {
		original, err = h.inspectOriginal(ctx)
		if err != nil {
			return Result{}, err
		}
		if !original.State.Running {
			return Result{}, errors.New("original container is no longer running; inspect state instead of repeating repair")
		}
		if err := h.verifyOriginalMounts(original); err != nil {
			return Result{}, err
		}
		if err := h.checkOriginalBinary(); err != nil {
			return Result{}, err
		}
		existing, err := h.inspectOptionalRecovery(ctx)
		if err != nil {
			return Result{}, err
		}
		if existing != nil {
			return Result{}, errors.New("recovery container already exists; inspect instead of repeating repair")
		}
		if err := h.fs.mkdirAll(h.paths.recoveryRoot, 0700); err != nil {
			return Result{}, fmt.Errorf("create durable recovery directory: %w", err)
		}
		barrierDir := filepath.Join(h.paths.recoveryRoot, "barrier")
		if err := h.fs.mkdir(barrierDir, 0700); err != nil {
			return Result{}, fmt.Errorf("create empty barrier directory: %w", err)
		}
		err = h.docker.stop(ctx, h.target.Original, 60)
		if err != nil {
			return Result{}, fmt.Errorf("stop original container: %w", err)
		}
		original, err = h.inspectOriginal(ctx)
		if err != nil {
			return Result{}, err
		}
		if original.State.Running {
			return Result{}, errors.New("original container remained running after stop")
		}
		if err := h.checkNoChainWriter(ctx); err != nil {
			return Result{}, err
		}
		if err := h.verifyOriginalMounts(original); err != nil {
			return Result{}, err
		}
		if err := h.checkOriginalBinary(); err != nil {
			return Result{}, err
		}
		return h.createAndStart(ctx, original)
	})
}

func (h host) launch(ctx context.Context) (Result, error) {
	original, err := h.inspectOriginal(ctx)
	if err != nil {
		return Result{}, err
	}
	if original.State.Running {
		return Result{}, errors.New("original container must be stopped before launch")
	}
	img, err := h.docker.inspectImage(ctx, recoveryImageID)
	if err != nil {
		return Result{}, fmt.Errorf("inspect pinned recovery image: %w", err)
	}
	if img.ID != recoveryImageID {
		return Result{}, errors.New("recovery image ID differs from incident pin")
	}
	if err := h.checkOriginalBinary(); err != nil {
		return Result{}, err
	}
	return h.withLock(true, func() (Result, error) {
		original, err = h.inspectOriginal(ctx)
		if err != nil {
			return Result{}, err
		}
		if original.State.Running {
			return Result{}, errors.New("original container started before recovery launch")
		}
		if err := h.verifyOriginalMounts(original); err != nil {
			return Result{}, err
		}
		if err := h.checkOriginalBinary(); err != nil {
			return Result{}, err
		}
		existing, err := h.inspectOptionalRecovery(ctx)
		if err != nil {
			return Result{}, err
		}
		if existing != nil {
			return Result{}, errors.New("recovery container already exists; inspect instead of repeating launch")
		}
		if err := h.checkBarrierDirEmpty(); err != nil {
			return Result{}, err
		}
		if err := h.checkNoChainWriter(ctx); err != nil {
			return Result{}, err
		}
		if err := h.verifyOriginalMounts(original); err != nil {
			return Result{}, err
		}
		if err := h.checkOriginalBinary(); err != nil {
			return Result{}, err
		}
		return h.createAndStart(ctx, original)
	})
}

func (h host) halt(ctx context.Context) (Result, error) {
	return h.withLock(false, func() (Result, error) {
		original, err := h.inspectOriginal(ctx)
		if err != nil {
			return Result{}, err
		}
		if original.State.Running {
			return Result{}, errors.New("original container must remain stopped while recovery is active")
		}
		recovery, err := h.inspectOptionalRecovery(ctx)
		if err != nil {
			return Result{}, err
		}
		if recovery == nil {
			return Result{}, errors.New("owned recovery container does not exist")
		}
		if err := h.verifyRecovery(*recovery); err != nil {
			return Result{}, err
		}
		data, err := h.fs.readFile(h.barrierPath())
		if err != nil {
			return Result{}, fmt.Errorf("read required replay barrier: %w", err)
		}
		barrier, err := h.checkBarrier(*recovery, data)
		if err != nil {
			return Result{}, err
		}
		if !recovery.State.Running {
			return Result{}, errors.New("recovery container is already stopped; inspect state instead of repeating halt")
		}
		if err := h.docker.kill(ctx, recovery.ID, "KILL"); err != nil {
			return Result{}, fmt.Errorf("kill recovery container: %w", err)
		}
		updated, err := h.docker.inspect(ctx, recovery.ID)
		if err != nil {
			return Result{}, err
		}
		recovery = &updated
		if recovery.State.Running {
			return Result{}, errors.New("recovery container remained running after SIGKILL")
		}
		state := stateOf(*recovery)
		return Result{Original: stateOf(original), Recovery: &state, Barrier: barrier}, nil
	})
}

func (h host) resume(ctx context.Context) (Result, error) {
	return h.withLock(false, func() (Result, error) {
		original, err := h.inspectOriginal(ctx)
		if err != nil {
			return Result{}, err
		}
		recovery, err := h.inspectOptionalRecovery(ctx)
		if err != nil {
			return Result{}, err
		}
		if recovery == nil {
			return Result{}, errors.New("owned recovery container does not exist")
		}
		if err := h.verifyRecovery(*recovery); err != nil {
			return Result{}, err
		}
		data, err := h.fs.readFile(h.barrierPath())
		if err != nil {
			return Result{}, fmt.Errorf("read required replay barrier: %w", err)
		}
		barrier, err := h.checkBarrier(*recovery, data)
		if err != nil {
			return Result{}, err
		}
		if recovery.State.Running || original.State.Running {
			return Result{}, errors.New("both original and recovery containers must be stopped before resume")
		}
		if err := h.checkNoChainWriter(ctx); err != nil {
			return Result{}, err
		}
		if err := h.checkOriginalBinary(); err != nil {
			return Result{}, err
		}
		if err := h.verifyOriginalMounts(original); err != nil {
			return Result{}, err
		}
		if err := h.docker.start(ctx, original.ID); err != nil {
			return Result{}, fmt.Errorf("start original container: %w", err)
		}
		original, err = h.docker.inspect(ctx, original.ID)
		if err != nil {
			return Result{}, err
		}
		if !original.State.Running {
			return Result{}, errors.New("original container did not enter running state")
		}
		recoveryState := stateOf(*recovery)
		return Result{Original: stateOf(original), Recovery: &recoveryState, Barrier: barrier}, nil
	})
}

func (h host) createAndStart(ctx context.Context, original dockerContainer) (Result, error) {
	if err := h.checkBarrierDirEmpty(); err != nil {
		return Result{}, err
	}
	name := h.recoveryName()
	network := h.network()
	config := dockerCreate{
		createConfig: createConfig{
			Image:      recoveryImageID,
			Entrypoint: []string{"/usr/bin/inferenced"},
			Cmd:        []string{"start", "--home", "/root/.inference", "--priv_validator_laddr", "tcp://0.0.0.0:26658", "--p2p.pex=false"},
			Env:        []string{"GNK_LAB_RECOVERY_BARRIER_CHAIN_ID=" + chainID, "GNK_LAB_RECOVERY_BARRIER_DIR=/barrier"},
			Labels:     map[string]string{"gnklab.incident": incidentLabel},
		},
		HostConfig: createHostConfig{NetworkMode: network, RestartPolicy: struct {
			Name string `json:"Name"`
		}{Name: "no"}, Mounts: []dockerMount{
			{Type: "bind", Source: h.paths.dataMount, Target: "/root/.inference"},
			{Type: "bind", Source: h.paths.identityDir, Target: "/gdc-identity", ReadOnly: true},
			{Type: "bind", Source: h.paths.genesisFile, Target: "/root/genesis.json", ReadOnly: true},
			{Type: "bind", Source: filepath.Join(h.paths.recoveryRoot, "barrier"), Target: "/barrier"},
		}},
		NetworkingConfig: createNetworkingConfig{EndpointsConfig: map[string]struct {
			Aliases []string `json:"Aliases"`
		}{network: {Aliases: []string{"node"}}}},
	}
	id, err := h.docker.create(ctx, name, config)
	if err != nil {
		return Result{}, fmt.Errorf("create recovery container: %w", err)
	}
	recovery, err := h.docker.inspect(ctx, id)
	if err != nil {
		return Result{}, fmt.Errorf("inspect newly created recovery container: %w", err)
	}
	if err := h.verifyRecovery(recovery); err != nil {
		return Result{}, fmt.Errorf("newly created recovery container identity: %w", err)
	}
	if err := h.docker.start(ctx, id); err != nil {
		return Result{}, fmt.Errorf("start recovery container: %w", err)
	}
	recovery, err = h.docker.inspect(ctx, id)
	if err != nil {
		return Result{}, fmt.Errorf("inspect started recovery container: %w", err)
	}
	if err := h.verifyRecovery(recovery); err != nil {
		return Result{}, fmt.Errorf("started recovery container identity: %w", err)
	}
	if !recovery.State.Running {
		return Result{}, errors.New("recovery container did not enter running state")
	}
	return Result{Original: stateOf(original), Recovery: ptrState(recovery)}, nil
}

func (h host) inspectOriginal(ctx context.Context) (dockerContainer, error) {
	c, err := h.docker.inspect(ctx, h.target.Original)
	if err != nil {
		return dockerContainer{}, fmt.Errorf("inspect pinned original container: %w", err)
	}
	if c.ID != h.target.Original {
		return dockerContainer{}, errors.New("original container ID differs from incident pin")
	}
	if c.Image != h.target.Image {
		return dockerContainer{}, errors.New("original container image ID differs from incident pin")
	}
	entrypoint, err := json.Marshal(c.Config.Entrypoint)
	if err != nil || string(entrypoint) != h.target.Entrypoint {
		return dockerContainer{}, errors.New("original container entrypoint differs from incident pin")
	}
	return c, nil
}

func (h host) verifyOriginalMounts(c dockerContainer) error {
	for _, m := range c.Mounts {
		if m.Destination == "/root/.inference" && m.Source == h.paths.dataMount && m.RW {
			return nil
		}
	}
	return errors.New("original container does not use the pinned inference-data mount")
}

func (h host) inspectOptionalRecovery(ctx context.Context) (*dockerContainer, error) {
	c, err := h.docker.inspect(ctx, h.recoveryName())
	if err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("inspect recovery container: %w", err)
	}
	return &c, nil
}

func (h host) verifyRecovery(c dockerContainer) error {
	if !idPattern.MatchString(c.ID) || c.Config.Image != recoveryImageID || c.Image != recoveryImageID {
		return errors.New("recovery container image identity differs from incident pin")
	}
	if c.Name != "/"+h.recoveryName() || c.Config.Labels["gnklab.incident"] != incidentLabel {
		return errors.New("recovery container ownership identity differs from incident pin")
	}
	if !equalStrings(c.Config.Entrypoint, []string{"/usr/bin/inferenced"}) ||
		!equalStrings(c.Config.Cmd, []string{"start", "--home", "/root/.inference", "--priv_validator_laddr", "tcp://0.0.0.0:26658", "--p2p.pex=false"}) {
		return errors.New("recovery container command differs from incident pin")
	}
	if !hasEnv(c.Config.Env, "GNK_LAB_RECOVERY_BARRIER_CHAIN_ID="+chainID) ||
		!hasEnv(c.Config.Env, "GNK_LAB_RECOVERY_BARRIER_DIR=/barrier") {
		return errors.New("recovery container barrier environment differs from incident pin")
	}
	if c.HostConfig.NetworkMode != h.network() {
		return errors.New("recovery container network differs from incident pin")
	}
	if c.HostConfig.RestartPolicy.Name != "no" || c.HostConfig.Privileged {
		return errors.New("recovery container restart or privilege settings differ from incident pin")
	}
	endpoint, ok := c.NetworkSettings.Networks[h.network()]
	if !ok || !hasEnv(endpoint.Aliases, "node") {
		return errors.New("recovery container network alias differs from incident pin")
	}
	if len(c.Mounts) != 4 ||
		!hasMount(c, h.paths.dataMount, "/root/.inference", false) ||
		!hasMount(c, h.paths.identityDir, "/gdc-identity", true) ||
		!hasMount(c, h.paths.genesisFile, "/root/genesis.json", true) ||
		!hasMount(c, filepath.Join(h.paths.recoveryRoot, "barrier"), "/barrier", false) {
		return errors.New("recovery container mounts differ from incident pin")
	}
	if c.State.Running && c.State.Pid <= 0 {
		return errors.New("recovery container is marked running without a process ID")
	}
	return nil
}

func hasMount(c dockerContainer, source, destination string, readOnly bool) bool {
	for _, m := range c.Mounts {
		if m.Source == source && m.Destination == destination && m.Type == "bind" && m.RW != readOnly {
			return true
		}
	}
	return false
}

func (h host) checkOriginalBinary() error {
	file, err := h.fs.openFile(h.paths.originalBinary, os.O_RDONLY, 0)
	if err != nil {
		return fmt.Errorf("read pinned original binary: %w", err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return fmt.Errorf("hash pinned original binary: %w", err)
	}
	if hex.EncodeToString(hash.Sum(nil)) != h.binHash {
		return errors.New("original inferenced binary hash differs from incident pin")
	}
	return nil
}

func (h host) checkPreABCI(ctx context.Context) error {
	if h.rpcCheck != nil {
		return h.rpcCheck(ctx)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, h.paths.rpcAddress, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("query pre-repair ABCI state: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("pre-repair ABCI HTTP status %d", resp.StatusCode)
	}
	var info struct {
		Result struct {
			Response struct {
				Height  string `json:"last_block_height"`
				AppHash string `json:"last_block_app_hash"`
			} `json:"response"`
		} `json:"result"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&info); err != nil {
		return fmt.Errorf("decode pre-repair ABCI state: %w", err)
	}
	if info.Result.Response.Height != "814729" || info.Result.Response.AppHash != preABCIHash {
		return errors.New("pre-repair ABCI height or AppHash differs from incident pin")
	}
	return nil
}

func (h host) checkNoChainWriter(ctx context.Context) error {
	original, err := h.inspectOriginal(ctx)
	if err != nil {
		return err
	}
	if original.State.Running {
		return errors.New("original container is still running")
	}
	allowed := map[string]bool{}
	for _, id := range strings.Split(h.target.Consumers, "|") {
		allowed[id] = true
	}
	consumers, err := h.docker.listVolumeConsumers(ctx, h.paths.dataMount)
	if err != nil {
		return fmt.Errorf("list inference-data volume consumers: %w", err)
	}
	for _, consumer := range consumers {
		if consumer.State != "running" {
			return fmt.Errorf("volume filter returned non-running consumer %s with state %q", consumer.ID, consumer.State)
		}
		if !idPattern.MatchString(consumer.ID) || !allowed[consumer.ID] {
			return fmt.Errorf("unexpected running inference-data consumer %s", consumer.ID)
		}
	}
	return h.checkProcesses()
}

func (h host) checkProcesses() error {
	resolvedRoot, err := h.fs.evalSymlinks(h.paths.dataRoot)
	if err != nil {
		return fmt.Errorf("resolve inference-data root: %w", err)
	}
	resolvedRoot = filepath.Clean(resolvedRoot)
	entries, err := h.fs.readDir(h.paths.procRoot)
	if err != nil {
		return fmt.Errorf("scan process table: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() || !allDigits(entry.Name()) {
			continue
		}
		proc := filepath.Join(h.paths.procRoot, entry.Name())
		comm, readErr := h.fs.readFile(filepath.Join(proc, "comm"))
		if readErr == nil && strings.TrimSpace(string(comm)) == "inferenced" {
			return fmt.Errorf("chain process %s is still running", entry.Name())
		}
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return fmt.Errorf("inspect process %s name: %w", entry.Name(), readErr)
		}
		fds, fdErr := h.fs.readDir(filepath.Join(proc, "fd"))
		if fdErr != nil {
			if errors.Is(fdErr, os.ErrNotExist) {
				continue
			}
			return fmt.Errorf("inspect process %s descriptors: %w", entry.Name(), fdErr)
		}
		for _, fd := range fds {
			target, linkErr := h.fs.readlink(filepath.Join(proc, "fd", fd.Name()))
			if linkErr != nil {
				if errors.Is(linkErr, os.ErrNotExist) {
					continue
				}
				return fmt.Errorf("inspect process %s descriptor %s: %w", entry.Name(), fd.Name(), linkErr)
			}
			if refersToData(target, resolvedRoot, h.paths.dataRoot) {
				return fmt.Errorf("chain DB descriptor remains open in process %s descriptor %s", entry.Name(), fd.Name())
			}
		}
	}
	return nil
}

func refersToData(target, resolvedRoot, configuredRoot string) bool {
	target = strings.TrimSuffix(target, " (deleted)")
	clean := filepath.Clean(target)
	for _, root := range []string{resolvedRoot, filepath.Clean(configuredRoot), "/root/.inference/data"} {
		if clean == root || strings.HasPrefix(clean, root+string(os.PathSeparator)) {
			return true
		}
	}
	return false
}

func (h host) checkBarrierDirEmpty() error {
	entries, err := h.fs.readDir(filepath.Join(h.paths.recoveryRoot, "barrier"))
	if err != nil {
		return fmt.Errorf("inspect recovery barrier directory: %w", err)
	}
	if len(entries) != 0 {
		return errors.New("recovery barrier directory is not empty")
	}
	return nil
}

type barrierRecord struct {
	ChainID  string `json:"chain_id"`
	Height   int    `json:"height"`
	Stage    string `json:"stage"`
	PID      int    `json:"pid"`
	Hostname string `json:"hostname"`
	BlockID  string `json:"block_id"`
	AppHash  string `json:"app_hash"`
}

func (h host) checkBarrier(c dockerContainer, data []byte) (json.RawMessage, error) {
	var barrier barrierRecord
	if err := json.Unmarshal(data, &barrier); err != nil {
		return nil, fmt.Errorf("decode replay barrier: %w", err)
	}
	if barrier.ChainID != chainID || barrier.Height != 814730 || barrier.Stage != "handshake-replay" ||
		barrier.PID != 1 || barrier.Hostname == "" || barrier.Hostname != c.Config.Hostname ||
		barrier.BlockID != barrierBlockID || barrier.AppHash != barrierAppHash {
		return nil, errors.New("replay barrier does not match the incident pin and recovery container")
	}
	return append(json.RawMessage(nil), data...), nil
}

func (h host) withLock(createRoot bool, fn func() (Result, error)) (Result, error) {
	if createRoot {
		if err := h.fs.mkdirAll(h.paths.recoveryRoot, 0700); err != nil {
			return Result{}, fmt.Errorf("create recovery lock directory: %w", err)
		}
	}
	flags := os.O_RDWR
	if createRoot {
		flags |= os.O_CREATE
	}
	lock, err := h.fs.openFile(filepath.Join(h.paths.recoveryRoot, "controller.lock"), flags, 0600)
	if err != nil {
		return Result{}, fmt.Errorf("open recovery lock: %w", err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return Result{}, fmt.Errorf("acquire recovery lock: %w", err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	return fn()
}

func stateOf(c dockerContainer) ContainerState {
	return ContainerState{ID: c.ID, Image: c.Image, Status: c.State.Status, Running: c.State.Running, PID: c.State.Pid, ExitCode: c.State.ExitCode}
}

func ptrState(c dockerContainer) *ContainerState {
	state := stateOf(c)
	return &state
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

func hasEnv(env []string, expected string) bool {
	for _, value := range env {
		if value == expected {
			return true
		}
	}
	return false
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func isNotFound(err error) bool {
	var apiErr *dockerHTTPError
	return errors.As(err, &apiErr) && apiErr.status == http.StatusNotFound
}
