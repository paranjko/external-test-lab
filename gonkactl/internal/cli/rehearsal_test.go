//go:build !windows

package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/capture"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

func TestRehearsalDefaultsToOfflinePreview(t *testing.T) {
	command := newRehearsalCommand(RehearsalDependencies{})
	command.SetArgs([]string{contract.Scenario})
	var output bytes.Buffer
	command.SetOut(&output)
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var result contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Phase != contract.Inspect || result.Status != "planned" || result.Mode != "preview" || result.Qualification != "not_run" || result.Mutation != "none" || result.Code != "offline_preview_only" || result.ExitCode != 0 {
		t.Fatalf("unexpected default preview: %+v", result)
	}
}

func TestRehearsalExplicitlyRefusesUnqualifiedEffects(t *testing.T) {
	cases := []struct {
		name string
		args []string
		code string
	}{
		{"apply without phase", []string{contract.Scenario, "--apply"}, "apply_not_supported_for_inspect"},
		{"stage", []string{contract.Scenario, "stage", "--apply"}, "phase_adapter_unavailable"},
		{"run", []string{contract.Scenario, "run", "--apply"}, "phase_adapter_unavailable"},
		{"verify without persisted identity", []string{contract.Scenario, "verify"}, "persisted_run_identity_required"},
		{"report without persisted identity", []string{contract.Scenario, "report"}, "persisted_run_identity_required"},
		{"capture missing binding", []string{contract.Scenario, "capture", "--apply"}, "capture_inputs_incomplete"},
		{"unknown phase", []string{contract.Scenario, "repair"}, "unsupported_phase"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			command := newRehearsalCommand(RehearsalDependencies{})
			command.SetArgs(test.args)
			var output bytes.Buffer
			command.SetOut(&output)
			err := command.Execute()
			var exit *ExitError
			if !errors.As(err, &exit) || exit.Code != 2 {
				t.Fatalf("expected refusal exit 2, got %v", err)
			}
			var result contract.Outcome
			if err := json.Unmarshal(output.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if result.Code != test.code || result.Status != "blocked" || result.Mutation != "none" {
				t.Fatalf("unexpected refusal: %+v", result)
			}
		})
	}
}

func TestCaptureUsesSignedProofVerifierWhenTrustPolicyIsPresent(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	fixture.dependencies.CaptureProofVerifier = nil
	command := newRehearsalCommand(fixture.dependencies)
	command.SetArgs(fixture.args)
	var output bytes.Buffer
	command.SetOut(&output)
	err := command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected invalid fixture proof refusal, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code == "capture_proof_verifier_unavailable" {
		t.Fatalf("trusted CLI did not compose signed verifier: %+v", outcome)
	}
	if outcome.Code != "capture_dispatch_refused" || outcome.Mutation != "none" {
		t.Fatalf("synthetic proof did not fail closed before capture: %+v", outcome)
	}
}

func TestRehearsalResumeUnknownIsReadOnly(t *testing.T) {
	root := privateTestDir(t)
	height := int64(2)
	binding := contract.RunBinding{SchemaVersion: contract.Version, RunID: "resume-unknown", Scenario: contract.Scenario,
		Workspace: root, OwnershipMarker: "owner", ChainID: "fixture", GenesisSHA256: strings.Repeat("a", 64),
		Heights: contract.Heights{Blockstore: 3, App: 2, Consensus: &height, FirstRepaired: 4}, BlockID: "block-3", AppHash: "app-2", AppHashHeight: 2,
		ToolVersion: "test", CatalogVersion: "fixture", InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64)},
		RuntimeIdentities: map[string]string{"standard": "sha256:fixture"}, Paths: map[string]string{}}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("capture", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(root, "lifecycle.json")
	before, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	command := newRehearsalCommand(RehearsalDependencies{})
	command.SetArgs([]string{contract.Scenario, "verify", "--workspace", root, "--run-id", binding.RunID, "--resume", binding.RunID})
	var output bytes.Buffer
	command.SetOut(&output)
	err = command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected refusal for unknown persisted run, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "persisted_run_unavailable" || outcome.Mutation != "none" {
		t.Fatalf("unexpected resume outcome: %+v", outcome)
	}
	after, err := os.ReadFile(journalPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("verify/resume changed quarantined journal: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "evidence")); !os.IsNotExist(err) {
		t.Fatalf("refused resume created evidence directory: %v", err)
	}
}

func TestRehearsalResumeNeverReplaysStageOrRun(t *testing.T) {
	for _, phase := range []string{"stage", "run"} {
		t.Run(phase, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "must-not-be-created")
			command := newRehearsalCommand(RehearsalDependencies{})
			command.SetArgs([]string{contract.Scenario, phase, "--apply", "--workspace", root, "--run-id", "resume-id", "--resume", "resume-id"})
			var output bytes.Buffer
			command.SetOut(&output)
			err := command.Execute()
			var exit *ExitError
			if !errors.As(err, &exit) || exit.Code != 2 {
				t.Fatalf("expected unqualified %s refusal, got %v", phase, err)
			}
			var outcome contract.Outcome
			if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
				t.Fatal(err)
			}
			if outcome.Code != "phase_adapter_unavailable" || outcome.Mutation != "none" {
				t.Fatalf("unexpected resume outcome: %+v", outcome)
			}
			if _, err := os.Stat(root); !os.IsNotExist(err) {
				t.Fatalf("resume created run path: %v", err)
			}
		})
	}
}

func TestRehearsalVerifyRejectsRepeatedManifestWithChangedFrozenDigest(t *testing.T) {
	root := privateTestDir(t)
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	seed := sha256.Sum256([]byte("core"))
	private := ed25519.NewKeyFromSeed(seed[:])
	// The run binding pins a different artifact payload, while this correctly
	// signed artifact retains all identity fields and the same input context.
	height := int64(2)
	binding := contract.RunBinding{SchemaVersion: contract.Version, RunID: "repeat-mismatch", Scenario: contract.Scenario,
		Workspace: root, OwnershipMarker: "owner", ChainID: "fixture", GenesisSHA256: strings.Repeat("a", 64),
		Heights: contract.Heights{Blockstore: 3, App: 2, Consensus: &height, FirstRepaired: 4}, BlockID: "block-3", AppHash: "app-2", AppHashHeight: 2,
		ToolVersion: "test", CatalogVersion: "fixture", InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64), "recovery_artifact": strings.Repeat("c", 64)},
		RuntimeIdentities: map[string]string{"standard": "sha256:fixture"}, Paths: map[string]string{}}
	payload := signedMetadataJSON(t, binding, mustInputContext(t, binding), "recovery_artifact", "core", now)
	artifactPath := filepath.Join(t.TempDir(), "artifact.json")
	writeDocument(t, artifactPath, payload, private)
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(root, "lifecycle.json")
	before, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	deps := RehearsalDependencies{TrustRoots: []input.TrustRoot{{KeyID: "core", Role: "core_maintainer", Scopes: map[string]bool{"capture": true}, PublicKey: private.Public().(ed25519.PublicKey)}},
		Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return now }}
	command := newRehearsalCommand(deps)
	command.SetArgs([]string{contract.Scenario, "verify", "--workspace", root, "--run-id", binding.RunID, "--recovery-artifact", artifactPath})
	var output bytes.Buffer
	command.SetOut(&output)
	err = command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected repeated artifact digest refusal, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "repeated_input_mismatch" {
		t.Fatalf("unexpected repeated-input result: %+v", outcome)
	}
	after, err := os.ReadFile(journalPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("repeated-input refusal modified lifecycle: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "evidence")); !os.IsNotExist(err) {
		t.Fatalf("repeated-input refusal created evidence: %v", err)
	}
}

func mustInputContext(t *testing.T, binding contract.RunBinding) string {
	t.Helper()
	digest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

func TestRootRegistersRecover(t *testing.T) {
	root := NewRoot()
	recover, _, err := root.Find([]string{"recover"})
	if err != nil || recover == nil {
		t.Fatalf("recover command not registered: %v", err)
	}
	if recover.Use != "recover <scenario> [phase]" {
		t.Fatalf("unexpected command use: %s", recover.Use)
	}
}

func TestRehearsalFirstVerifyRequiresBothSignedRunPoliciesWithoutMutation(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	journal, err := lifecycle.Open(fixture.binding.Workspace, fixture.binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(fixture.binding.Workspace, "lifecycle.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	command := newRehearsalCommand(fixture.dependencies)
	command.SetArgs([]string{contract.Scenario, "verify", "--workspace", fixture.binding.Workspace, "--run-id", fixture.binding.RunID, "--binding", fixture.args[8]})
	var output bytes.Buffer
	command.SetOut(&output)
	err = command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected missing signed policy refusal, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "signed_verification_inputs_required" || outcome.Status != "blocked" {
		t.Fatalf("unexpected first verify outcome: %+v", outcome)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("missing policy refusal mutated journal: %v", err)
	}
}

func TestCaptureQuotaSumsFilesAndRejectsOverflow(t *testing.T) {
	quota, err := captureQuota([]catalog.ArtifactFile{{Size: 7}, {Size: 11}}, 0)
	if err != nil || quota != 18 {
		t.Fatalf("derived quota=%d err=%v, want sum 18", quota, err)
	}
	quota, err = captureQuota([]catalog.ArtifactFile{{Size: 7}, {Size: 11}}, 40)
	if err != nil || quota != 40 {
		t.Fatalf("explicit quota=%d err=%v, want configured 40", quota, err)
	}
	if _, err := captureQuota([]catalog.ArtifactFile{{Size: int64(^uint64(0) >> 1)}, {Size: 1}}, 0); err == nil {
		t.Fatal("overflowing signed file-size sum accepted")
	}
}

func TestRehearsalCaptureDispatchesSignedFrozenCopyAndKeepsRuntimePhasesClosed(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	deps := fixture.dependencies
	command := newRehearsalCommand(deps)
	command.SetArgs(fixture.args)
	var output bytes.Buffer
	command.SetOut(&output)
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Status != "succeeded" || outcome.Code != "capture_succeeded" || outcome.Qualification != "not_run" || outcome.Mutation != "owned_workspace" || len(outcome.Receipts) != 1 || outcome.Receipts[0].State != contract.Succeeded {
		t.Fatalf("unexpected local capture result: %+v", outcome)
	}
	got, err := os.ReadFile(filepath.Join(fixture.binding.Paths["source"], "blockstore.db"))
	if err != nil || !bytes.Equal(got, fixture.data) {
		t.Fatalf("captured bytes mismatch: %v", err)
	}
	loaded, err := session.Load(fixture.binding.Workspace, fixture.binding.RunID)
	if err != nil || len(loaded.Receipts) != 2 || loaded.Receipts[1].Phase != contract.Capture || loaded.Receipts[1].State != contract.Succeeded {
		t.Fatalf("capture was not persisted in journal: %+v, %v", loaded, err)
	}
	for _, phase := range []string{"stage", "run"} {
		cmd := newRehearsalCommand(deps)
		cmd.SetArgs([]string{contract.Scenario, phase, "--apply", "--workspace", fixture.binding.Workspace, "--run-id", fixture.binding.RunID})
		var result bytes.Buffer
		cmd.SetOut(&result)
		err := cmd.Execute()
		var exit *ExitError
		if !errors.As(err, &exit) || exit.Code != 2 {
			t.Fatalf("expected %s refusal, got %v", phase, err)
		}
		var blocked contract.Outcome
		if err := json.Unmarshal(result.Bytes(), &blocked); err != nil {
			t.Fatal(err)
		}
		if blocked.Code != "phase_adapter_unavailable" || blocked.Mutation != "none" {
			t.Fatalf("%s unexpectedly opened: %+v", phase, blocked)
		}
	}
}

func TestRehearsalCaptureLoadsExplicitTrustPolicyAndRequiresTrustMaterial(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	deps := fixture.dependencies
	deps.TrustRoots = nil
	deps.Revocations = input.RevocationSnapshot{}
	command := newRehearsalCommand(deps)
	command.SetArgs(fixture.args)
	var output bytes.Buffer
	command.SetOut(&output)
	err := command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("capture without trust policy must refuse, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "capture_trust_policy_required" || outcome.Mutation != "none" {
		t.Fatalf("unexpected missing-trust outcome: %+v", outcome)
	}

	type trustRoot struct {
		KeyID        string   `json:"key_id"`
		Role         string   `json:"role"`
		Scopes       []string `json:"scopes"`
		PublicKeyHex string   `json:"public_key_hex"`
	}
	roots := make([]trustRoot, 0, len(fixture.dependencies.TrustRoots))
	for _, root := range fixture.dependencies.TrustRoots {
		scopes := make([]string, 0, len(root.Scopes))
		for scope := range root.Scopes {
			scopes = append(scopes, scope)
		}
		roots = append(roots, trustRoot{KeyID: root.KeyID, Role: root.Role, Scopes: scopes, PublicKeyHex: hex.EncodeToString(root.PublicKey)})
	}
	policyBytes, err := json.Marshal(struct {
		SchemaVersion string      `json:"schema_version"`
		Roots         []trustRoot `json:"roots"`
		Revocations   struct {
			ValidUntil string   `json:"valid_until"`
			Revoked    []string `json:"revoked"`
		} `json:"revocations"`
	}{SchemaVersion: rehearsalTrustSchema, Roots: roots, Revocations: struct {
		ValidUntil string   `json:"valid_until"`
		Revoked    []string `json:"revoked"`
	}{ValidUntil: "2026-10-20T00:00:00Z", Revoked: []string{}}})
	if err != nil {
		t.Fatal(err)
	}
	trustPath := filepath.Join(t.TempDir(), "trust.json")
	if err := os.WriteFile(trustPath, policyBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	command = newRehearsalCommand(deps)
	command.SetArgs(append(append([]string{}, fixture.args...), "--trust-policy", trustPath))
	output.Reset()
	command.SetOut(&output)
	if err := command.Execute(); err != nil {
		t.Fatalf("capture with explicit trust policy failed: %v\n%s", err, output.String())
	}
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "capture_succeeded" || outcome.Qualification != "not_run" {
		t.Fatalf("unexpected policy-backed capture outcome: %+v", outcome)
	}
}

func TestRehearsalCaptureFailsClosedWithoutInjectedProofVerifier(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	fixture.dependencies.CaptureProofVerifier = nil
	command := newRehearsalCommand(fixture.dependencies)
	command.SetArgs(fixture.args)
	var output bytes.Buffer
	command.SetOut(&output)
	err := command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected synthetic proof refusal, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "capture_dispatch_refused" || outcome.Mutation != "none" {
		t.Fatalf("automatic signed verifier did not fail closed: %+v", outcome)
	}
	if _, err := os.Stat(fixture.binding.Paths["source"]); !os.IsNotExist(err) {
		t.Fatalf("missing verifier mutated capture destination: %v", err)
	}
}

func TestRehearsalCaptureRefusesInterruptedOrStaleJournalWithoutRepair(t *testing.T) {
	fixture := newSignedCaptureCLI(t)
	journal, err := lifecycle.Open(fixture.binding.Workspace, fixture.binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("frozen_export_copy", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(fixture.binding.Workspace, "lifecycle.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	command := newRehearsalCommand(fixture.dependencies)
	command.SetArgs(fixture.args)
	var output bytes.Buffer
	command.SetOut(&output)
	err = command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected interrupted journal refusal, got %v", err)
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatal(err)
	}
	if outcome.Code != "capture_run_journal_required" || outcome.Mutation != "none" {
		t.Fatalf("unexpected stale-journal result: %+v", outcome)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("interrupted journal changed during refusal: %v", err)
	}
	if _, err := os.Stat(fixture.binding.Paths["source"]); !os.IsNotExist(err) {
		t.Fatalf("stale-journal refusal copied files: %v", err)
	}
}

func privateTestDir(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

type signedCaptureFixture struct {
	binding      contract.RunBinding
	data         []byte
	args         []string
	dependencies RehearsalDependencies
}

func newSignedCaptureCLI(t *testing.T) signedCaptureFixture {
	t.Helper()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	workspaceParent, exportRoot, inputDir := t.TempDir(), t.TempDir(), t.TempDir()
	workspace := filepath.Join(workspaceParent, "fresh-run")
	sourceRoot := filepath.Join(workspace, "source")
	height := int64(3)
	data := []byte("synthetic frozen blockstore bytes")
	fileHash := sha256.Sum256(data)
	keys := map[string]ed25519.PrivateKey{}
	roles := []struct{ id, role, scope string }{
		{"archive", "archive_owner", "capture"}, {"catalog", "catalog", catalog.CatalogScope},
		{"core", "core", catalog.ArtifactScope}, {"operator", "operator", "capture"},
	}
	roots := make([]input.TrustRoot, 0, len(roles))
	for _, item := range roles {
		seed := sha256.Sum256([]byte("synthetic cli " + item.id))
		private := ed25519.NewKeyFromSeed(seed[:])
		keys[item.id] = private
		roots = append(roots, input.TrustRoot{KeyID: item.id, Role: item.role, Scopes: map[string]bool{item.scope: true}, PublicKey: private.Public().(ed25519.PublicKey)})
	}
	digestKeys := []string{"catalog", "recovery_artifact", "source_manifest", "capture_approval", "snapshot_freeze", "layout_proof", "inventory_receipt", "witness_1", "witness_2", "offline_reader"}
	inputDigests := map[string]string{}
	for _, key := range digestKeys {
		inputDigests[key] = strings.Repeat("0", 64)
	}
	runtimeDigest := sha256.Sum256([]byte("synthetic standard runtime"))
	binding := contract.RunBinding{SchemaVersion: contract.Version, RunID: "cli-capture-integration", Scenario: contract.Scenario,
		Workspace: workspace, OwnershipMarker: "synthetic-cli-owner", ChainID: "synthetic-chain", GenesisSHA256: strings.Repeat("a", 64),
		Heights: contract.Heights{Blockstore: 4, App: 3, Consensus: &height, FirstRepaired: 5}, BlockID: "block-4", AppHash: "app-3", AppHashHeight: 3,
		ToolVersion: "synthetic-test", CatalogVersion: "synthetic-catalog-v1", InputDigests: inputDigests,
		RuntimeIdentities: map[string]string{"standard": hex.EncodeToString(runtimeDigest[:])},
		Paths:             map[string]string{"source": sourceRoot, "export": exportRoot}}
	inputContext, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	metadata := func(kind, scope, key string) contract.SignedMetadata {
		return contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: scope, KeyID: key,
			RunID: binding.RunID, BindingDigest: inputContext, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
			IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
	}
	manifest := contract.SourceManifest{SignedMetadata: metadata("source_manifest", "capture", "archive"), SnapshotID: "synthetic-snapshot",
		Checkpoint: "checkpoint-4", Backend: "fixture", Layout: "single", BackendVersion: "fixture-v1", Frozen: true,
		Heights: binding.Heights, Files: []contract.ExportFile{{Path: "blockstore.db", SHA256: hex.EncodeToString(fileHash[:]), Size: int64(len(data))}}, Components: []string{"blockstore"}}
	sourcePayload, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["source_manifest"] = contract.PayloadDigest(sourcePayload)
	buildDigest := sha256.Sum256([]byte("synthetic candidate build"))
	builds := map[string]string{"core": hex.EncodeToString(buildDigest[:])}
	runtimes := map[string]string{"standard": binding.RuntimeIdentities["standard"]}
	scenario := catalog.Scenario{ID: catalog.CatalogScope, Description: "synthetic capture-only scenario", BuildDigests: builds, RuntimeDigests: runtimes,
		Backends: []string{"fixture"}, Layouts: []string{"single"}, BackendVersions: map[string][]string{"fixture": {"fixture-v1"}},
		Files:         []catalog.FileRule{{Path: "blockstore.db", Required: true, Kind: "file", Component: "blockstore"}},
		MigrationKeys: []catalog.MigrationKey{}, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired}
	catalogPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		Scenarios []catalog.Scenario `json:"scenarios"`
	}{metadata(catalog.CatalogKind, catalog.CatalogScope, "catalog"), []catalog.Scenario{scenario}})
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["catalog"] = contract.PayloadDigest(catalogPayload)
	artifact := catalog.RecoveryArtifact{ScenarioID: scenario.ID, BuildDigests: builds, RuntimeDigests: runtimes, Backend: "fixture", BackendVersion: "fixture-v1", Layout: "single",
		Files:         []catalog.ArtifactFile{{Path: "blockstore.db", SHA256: hex.EncodeToString(fileHash[:]), Size: int64(len(data)), Component: "blockstore"}},
		MigrationKeys: []catalog.MigrationKey{}, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired}
	artifactPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		catalog.RecoveryArtifact
	}{metadata(catalog.ArtifactKind, catalog.ArtifactScope, "core"), artifact})
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(artifactPayload)
	proofs := map[string][]byte{"snapshot_freeze": []byte("synthetic freeze receipt"), "layout_proof": []byte("synthetic layout receipt"), "inventory_receipt": []byte("synthetic inventory receipt"),
		"witness_1": []byte("synthetic independent source one"), "witness_2": []byte("synthetic independent source two"), "offline_reader": []byte("synthetic offline reader")}
	for key, payload := range proofs {
		binding.InputDigests[key] = contract.PayloadDigest(payload)
	}
	approvalPayload, err := json.Marshal(metadata("approval", "capture", "operator"))
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["capture_approval"] = contract.PayloadDigest(approvalPayload)
	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatalf("synthetic binding invalid: %v", err)
	}
	writeTestFile(t, filepath.Join(exportRoot, "blockstore.db"), data, 0600)
	inputPaths := map[string]string{}
	for _, key := range []string{"snapshot_freeze", "layout_proof", "inventory_receipt", "witness_1", "witness_2", "offline_reader"} {
		path := filepath.Join(inputDir, key+".proof.json")
		writeTestFile(t, path, proofs[key], 0600)
		inputPaths[key] = path
	}
	evidencePath := filepath.Join(inputDir, "capture-evidence.json")
	evidenceJSON, err := json.Marshal(captureEvidencePaths{Freeze: inputPaths["snapshot_freeze"], Layout: inputPaths["layout_proof"], Inventory: inputPaths["inventory_receipt"],
		Witnesses: []string{inputPaths["witness_1"], inputPaths["witness_2"]}, OfflineReader: inputPaths["offline_reader"]})
	if err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, evidencePath, evidenceJSON, 0600)
	bindingPath := filepath.Join(inputDir, "binding.json")
	bindingJSON, err := json.Marshal(binding)
	if err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, bindingPath, bindingJSON, 0600)
	sourcePath, catalogPath, artifactPath, approvalPath := filepath.Join(inputDir, "source.json"), filepath.Join(inputDir, "catalog.json"), filepath.Join(inputDir, "artifact.json"), filepath.Join(inputDir, "approval.json")
	writeDocument(t, sourcePath, sourcePayload, keys["archive"])
	writeDocument(t, catalogPath, catalogPayload, keys["catalog"])
	writeDocument(t, artifactPath, artifactPayload, keys["core"])
	writeDocument(t, approvalPath, approvalPayload, keys["operator"])
	verifier := cliFixtureProofVerifier{snapshotID: manifest.SnapshotID}
	deps := RehearsalDependencies{TrustRoots: roots, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return now },
		CaptureProofVerifier: verifier, CaptureMaxBytes: int64(len(data)), CaptureReserveBytes: 0}
	args := []string{contract.Scenario, "capture", "--apply", "--run-id", binding.RunID, "--workspace", binding.Workspace,
		"--binding", bindingPath, "--source-manifest", sourcePath, "--catalog", catalogPath, "--recovery-artifact", artifactPath,
		"--capture-approval", approvalPath, "--capture-evidence", evidencePath}
	return signedCaptureFixture{binding: binding, data: data, args: args, dependencies: deps}
}

type cliFixtureProofVerifier struct{ snapshotID string }

func (v cliFixtureProofVerifier) binding(b contract.RunBinding, raw []byte) capture.VerificationBinding {
	digest, _ := contract.Digest(b)
	return capture.VerificationBinding{RunID: b.RunID, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256, BindingDigest: digest, PayloadSHA256: contract.PayloadDigest(raw)}
}

func (v cliFixtureProofVerifier) VerifySnapshotInputs(_ context.Context, b contract.RunBinding, m contract.SourceManifest, freeze, layout, inventory []byte) (capture.SnapshotVerification, error) {
	filesDigest, _ := contract.Digest(m.Files)
	return capture.SnapshotVerification{VerificationBinding: v.binding(b, freeze), FreezePayloadSHA256: contract.PayloadDigest(freeze), LayoutPayloadSHA256: contract.PayloadDigest(layout), InventoryPayloadSHA256: contract.PayloadDigest(inventory),
		SnapshotID: v.snapshotID, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, InventorySHA256: filesDigest, Frozen: true}, nil
}

func (v cliFixtureProofVerifier) VerifyWitness(_ context.Context, b contract.RunBinding, raw []byte) (capture.WitnessVerification, error) {
	return capture.WitnessVerification{VerificationBinding: v.binding(b, raw), SourceIdentity: string(raw), SignerKeyID: string(raw), BlockID: b.BlockID, BlockHeight: b.Heights.Blockstore, AppHash: b.AppHash, AppHashHeight: b.Heights.App,
		ValidatorSetSHA256: strings.Repeat("e", 64), ValidatorSetComplete: true, SignerIDs: []string{"fixture-v1", "fixture-v2", "fixture-v3"}, SignedVotingPower: 7, TotalVotingPower: 9}, nil
}

func (v cliFixtureProofVerifier) VerifyOfflineReader(_ context.Context, b contract.RunBinding, raw []byte) (capture.OfflineReaderVerification, error) {
	if b.Heights.Consensus == nil {
		return capture.OfflineReaderVerification{}, errors.New("consensus height absent")
	}
	return capture.OfflineReaderVerification{VerificationBinding: v.binding(b, raw), SnapshotID: v.snapshotID, ConsensusHeight: *b.Heights.Consensus}, nil
}

func TestRehearsalResumeMustMatchRunID(t *testing.T) {
	command := newRehearsalCommand(RehearsalDependencies{})
	command.SetArgs([]string{contract.Scenario, "--run-id", "run-a", "--resume", "run-b"})
	var output bytes.Buffer
	command.SetOut(&output)
	err := command.Execute()
	var exit *ExitError
	if !errors.As(err, &exit) || exit.Code != 2 {
		t.Fatalf("expected resume refusal, got %v", err)
	}
	var result contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Code != "resume_run_id_mismatch" || result.Status != "blocked" {
		t.Fatalf("unexpected resume outcome: %+v", result)
	}
}

func signedMetadataJSON(t *testing.T, binding contract.RunBinding, inputContext, kind, keyID string, now time.Time) []byte {
	t.Helper()
	payload, err := json.Marshal(contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: "capture", KeyID: keyID,
		RunID: binding.RunID, BindingDigest: inputContext, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
		IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func writeDocument(t *testing.T, path string, payload []byte, key ed25519.PrivateKey) {
	t.Helper()
	sum := sha256.Sum256(payload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	document, err := json.Marshal(contract.SignedDocument{Payload: payload, SignatureHex: hex.EncodeToString(ed25519.Sign(key, message))})
	if err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, path, document, 0600)
}

func writeTestFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
}
