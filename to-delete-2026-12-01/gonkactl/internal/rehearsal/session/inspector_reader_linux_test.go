//go:build linux

package session

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type syntheticInspectorFS struct{}

func (syntheticInspectorFS) checkOutputRoot(root string, max, dump int64) error {
	if root == "" || max <= 0 || dump <= 0 {
		return os.ErrInvalid
	}
	return nil
}
func (syntheticInspectorFS) checkWorkspace(root string, max int64) error {
	if root == "" || max <= 0 {
		return os.ErrInvalid
	}
	return nil
}

// This test is launched only by InspectorSnapshotReader's private helper mode.
// It is an ordinary synthetic executable process and never opens a database.
func TestInspectorHelperProcess(t *testing.T) {
	if os.Getenv("GNKLAB_INSPECTOR_HELPER") != "1" {
		return
	}
	args := os.Args
	start := -1
	for i, arg := range args {
		if arg == "--allowed-root" {
			start = i
			break
		}
	}
	if start < 0 {
		os.Exit(21)
	}
	var output string
	for i := start; i < len(args); i++ {
		if args[i] == "--out" && i+1 < len(args) {
			output = args[i+1]
		}
	}
	if output == "" || os.Mkdir(output, 0700) != nil {
		os.Exit(22)
	}
	if os.Getenv("GNKLAB_INSPECTOR_HELPER_FAILURE") == "1" {
		_ = os.WriteFile(filepath.Join(output, "app-kv.jsonl"), []byte("partial\n"), 0600)
		_, _ = fmt.Fprintln(os.Stderr, "synthetic inspector failure")
		os.Exit(7)
	}
	if os.Getenv("GNKLAB_INSPECTOR_HELPER_LOG_OVERFLOW") == "1" {
		_, _ = fmt.Fprint(os.Stderr, strings.Repeat("x", 4096))
		time.Sleep(2 * time.Second)
		os.Exit(0)
	}
	key, value := []byte("synthetic-key"), []byte{0, 0xff, 7}
	keyHash, valueHash := sha256.Sum256(key), sha256.Sum256(value)
	dumpRecord, _ := json.Marshal(map[string]string{
		"store":        "synthetic",
		"key_base64":   base64.StdEncoding.EncodeToString(key),
		"value_base64": base64.StdEncoding.EncodeToString(value),
		"key_sha256":   hex.EncodeToString(keyHash[:]),
		"value_sha256": hex.EncodeToString(valueHash[:]),
	})
	dump := append(dumpRecord, '\n')
	dumpHash := sha256.Sum256(dump)
	summary, _ := json.Marshal(map[string]any{
		"kv_dump_file": "app-kv.jsonl", "kv_dump_sha256": hex.EncodeToString(dumpHash[:]),
		"kv_dump_record_count": 1, "kv_dump_logical_bytes": len(key) + len(value),
		"stores": []map[string]any{{"name": "synthetic", "kv_count": 1, "logical_bytes": len(key) + len(value)}},
	})
	if os.WriteFile(filepath.Join(output, "app-kv.jsonl"), dump, 0600) != nil || os.WriteFile(filepath.Join(output, "summary.json"), summary, 0600) != nil {
		os.Exit(23)
	}
	os.Exit(0)
}

func TestInspectorSnapshotReaderPreservesFailureReceiptAndOwnedPartials(t *testing.T) {
	workspace, binding, manifest, config := syntheticInspectorFixture(t)
	config.helperProcess = true
	config.helperFailure = true
	config.filesystem = syntheticInspectorFS{}
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err == nil || !strings.Contains(err.Error(), "exit status 7") {
		t.Fatalf("synthetic producer failure not propagated: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(workspace, "evidence", "inspector", binding.RunID, "execution.json"))
	if err != nil {
		t.Fatal(err)
	}
	var receipt inspectorExecution
	if err := json.Unmarshal(raw, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "failed" || receipt.ExitCode != 7 || !strings.Contains(receipt.Stderr, "synthetic inspector failure") || !contract.IsDigest(receipt.PartialDump.SHA256) {
		t.Fatalf("failure receipt did not preserve bounded logs/partial digests: %+v", receipt)
	}
	if _, err := os.Stat(receipt.PreservedCopy); err != nil {
		t.Fatalf("failed disposable copy was not preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(receipt.PreservedOutput, "output", "app-kv.jsonl")); err != nil {
		t.Fatalf("partial output was not preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(workspace, "evidence", "inspector", binding.RunID, "app-kv.jsonl")); err != nil {
		t.Fatalf("partial raw output was not retained in run evidence: %v", err)
	}
}

func TestInspectorSnapshotReaderBoundsAndKillsLogFloodingProducer(t *testing.T) {
	workspace, binding, manifest, config := syntheticInspectorFixture(t)
	config.helperLogOverflow = true
	config.MaxLogBytes = 128
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err == nil {
		t.Fatal("log-flooding helper unexpectedly succeeded")
	}
	raw, err := os.ReadFile(filepath.Join(workspace, "evidence", "inspector", binding.RunID, "execution.json"))
	if err != nil {
		t.Fatal(err)
	}
	var receipt inspectorExecution
	if err := json.Unmarshal(raw, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "failed" || receipt.StderrObservedBytes <= config.MaxLogBytes || receipt.StderrRetainedBytes != config.MaxLogBytes || !receipt.StderrTruncated || !contract.IsDigest(receipt.StderrRetainedSHA256) || len(receipt.Stderr) > int(config.MaxLogBytes) {
		t.Fatalf("log flood was not bounded and recorded: %+v", receipt)
	}
}

func TestInspectorSnapshotReaderRejectsSameSizeSourceMutationBeforeProducer(t *testing.T) {
	workspace, binding, manifest, config := syntheticInspectorFixture(t)
	manifest.Files = append([]contract.ExportFile(nil), manifest.Files...)
	manifest.Files[0].SHA256 = strings.Repeat("d", 64)
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err == nil || !strings.Contains(err.Error(), "differs from authenticated source manifest") {
		t.Fatalf("same-size content mismatch was not rejected before producer: %v", err)
	}
	if _, err := os.Stat(filepath.Join(workspace, "evidence", "inspector")); !os.IsNotExist(err) {
		t.Fatalf("producer/evidence ran before authenticated inventory check: %v", err)
	}
	entries, err := os.ReadDir(workspace)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".inspector-copy-") {
			t.Fatalf("rejected disposable copy was unexpectedly preserved: %s", entry.Name())
		}
	}
}

func TestInspectorSnapshotReaderFailsClosedWithoutManifest(t *testing.T) {
	_, binding, _, config := syntheticInspectorFixture(t)
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reader.ReadSnapshot(context.Background(), binding); err == nil || !strings.Contains(err.Error(), "caller-authenticated source manifest") {
		t.Fatalf("reader inferred trusted inventory without manifest: %v", err)
	}
}

func TestInspectorSnapshotReaderRejectsSpecialSourceEntries(t *testing.T) {
	_, binding, manifest, config := syntheticInspectorFixture(t)
	path := filepath.Join(binding.Paths["source"], "data", "application.db", "zz-fifo")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err == nil || !strings.Contains(err.Error(), "special inspector source entry") {
		t.Fatalf("FIFO source entry was not rejected: %v", err)
	}
}

func TestInspectorSnapshotReaderUsesDisposableCopyAndPersistsLocalReceipt(t *testing.T) {
	workspace, binding, manifest, config := syntheticInspectorFixture(t)
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Stores) != 1 || snapshot.Stores[0].Name != "synthetic" || string(snapshot.Stores[0].Entries[0].Value) != string([]byte{0, 0xff, 7}) {
		t.Fatalf("synthetic snapshot not decoded: %#v", snapshot)
	}
	if _, err := os.Stat(filepath.Join(binding.Paths["source"], "data", "application.db", "fixture")); err != nil {
		t.Fatalf("original source was changed or removed: %v", err)
	}
	entries, err := os.ReadDir(workspace)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".inspector-copy-") {
			t.Fatalf("successful disposable database copy was not removed: %s", entry.Name())
		}
	}
	receiptRaw, err := os.ReadFile(filepath.Join(workspace, "evidence", "inspector", binding.RunID, "execution.json"))
	if err != nil {
		t.Fatal(err)
	}
	var receipt inspectorExecution
	if err := json.Unmarshal(receiptRaw, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "completed-local-inspection" || receipt.Qualification != "local-only; not runtime-qualified" || receipt.Producer.SHA256 != config.BinarySHA256 || !contract.IsDigest(receipt.SnapshotSHA256) {
		t.Fatalf("local execution receipt is incomplete or overclaims: %+v", receipt)
	}
	for _, name := range []string{"summary.json", "app-kv.jsonl"} {
		if _, err := os.Stat(filepath.Join(workspace, "evidence", "inspector", binding.RunID, name)); err != nil {
			t.Fatalf("successful raw output %s was not retained: %v", name, err)
		}
	}
}

func syntheticInspectorFixture(t *testing.T) (string, contract.RunBinding, contract.SourceManifest, InspectorConfig) {
	t.Helper()
	workspace := t.TempDir()
	if err := os.Chmod(workspace, 0700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(workspace, "source")
	var manifestFiles []contract.ExportFile
	for _, db := range []string{"application.db", "state.db", "blockstore.db"} {
		if err := os.MkdirAll(filepath.Join(source, "data", db), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(source, "data", db, "fixture"), []byte("unchanged"), 0600); err != nil {
			t.Fatal(err)
		}
		body := []byte("unchanged")
		sum := sha256.Sum256(body)
		manifestFiles = append(manifestFiles, contract.ExportFile{Path: filepath.ToSlash(filepath.Join("data", db, "fixture")), SHA256: hex.EncodeToString(sum[:]), Size: int64(len(body))})
	}
	if err := os.Chmod(source, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(workspace, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	tempRoot := filepath.Join(workspace, "inspector-temp")
	if err := os.Mkdir(tempRoot, 0700); err != nil {
		t.Fatal(err)
	}

	producer := filepath.Join(workspace, "producer-binary")
	currentExe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(currentExe)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(producer, data, 0700); err != nil {
		t.Fatal(err)
	}
	producerHash := sha256.Sum256(data)
	producerSHA := hex.EncodeToString(producerHash[:])
	copyLimit := int64(1 << 20)
	consensus := int64(10)
	binding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "inspector-fixture", Scenario: contract.Scenario,
		Workspace: workspace, OwnershipMarker: "fixture-owner", ChainID: "fixture-chain",
		GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 10, App: 10, Consensus: &consensus, FirstRepaired: 11},
		BlockID: "fixture-block", AppHash: "fixture-app", AppHashHeight: 10, ToolVersion: "fixture", CatalogVersion: "fixture-catalog",
		InputDigests:      map[string]string{"source_manifest": strings.Repeat("b", 64), "producer-binary": producerSHA},
		RuntimeIdentities: map[string]string{"node": "synthetic"},
		Paths:             map[string]string{"source": source, "producer-binary": producer, "inspector-temp": tempRoot},
	}
	inputBindingDigest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	manifestNow := time.Now().UTC()
	manifest := contract.SourceManifest{
		SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture", KeyID: "synthetic-test", RunID: binding.RunID, BindingDigest: inputBindingDigest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, IssuedAt: manifestNow.Add(-time.Minute), ExpiresAt: manifestNow.Add(time.Hour)},
		SnapshotID:     "synthetic-snapshot", Checkpoint: "synthetic-checkpoint", Backend: "goleveldb", Layout: "synthetic-layout", BackendVersion: "test-v1", Frozen: true,
		Heights: binding.Heights, Files: manifestFiles, Components: []string{"blockstore"},
	}
	config := InspectorConfig{
		BinaryPath: producer, BinarySHA256: producerSHA, Version: "synthetic", SourceCommit: strings.Repeat("c", 40),
		TempRoot: tempRoot, MaxCopyBytes: copyLimit, MaxDumpBytes: 1 << 16, MaxOutputFSBytes: 1 << 20, ReserveBytes: 4096,
		Timeout: 10 * time.Second, MaxLogBytes: 4096, helperProcess: true, filesystem: syntheticInspectorFS{},
	}
	return workspace, binding, manifest, config
}

func TestInspectorSnapshotReaderFailsClosedWithoutDedicatedBoundedTmpfs(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	reader, err := NewInspectorSnapshotReader(InspectorConfig{
		BinaryPath: filepath.Join(root, "producer"), BinarySHA256: strings.Repeat("0", 64), Version: "v", SourceCommit: strings.Repeat("c", 40),
		TempRoot: root, MaxCopyBytes: 10, MaxDumpBytes: 10, MaxOutputFSBytes: 20, ReserveBytes: 1, Timeout: time.Second, MaxLogBytes: 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	err = reader.checkOutputFS()
	if err == nil || !strings.Contains(err.Error(), "dedicated tmpfs") {
		t.Fatalf("ordinary directory was not rejected as output target: %v", err)
	}
}

func TestInspectorSnapshotReaderRejectsProducerBindingMismatch(t *testing.T) {
	workspace, binding, manifest, config := syntheticInspectorFixture(t)
	config.BinaryPath += ".not-bound"
	reader, err := NewInspectorSnapshotReader(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = reader.ReadManifestSnapshot(context.Background(), binding, manifest)
	if err == nil || !strings.Contains(err.Error(), "must exactly match the run binding") {
		t.Fatalf("producer binding mismatch was not rejected: %v", err)
	}
	if _, err := os.Stat(filepath.Join(workspace, "evidence", "inspector")); !os.IsNotExist(err) {
		t.Fatalf("binding mismatch caused evidence mutation: %v", err)
	}
}
