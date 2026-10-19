// Package session loads persisted rehearsal evidence without resuming or
// mutating a lifecycle journal. Its verdicts describe local evidence only.
//go:build linux

package session

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/capture"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

const (
	oracleName       = "oracle.json"
	verificationName = "verification.json"
	reportJSONName   = "report.json"
	reportMDName     = "report.md"
	maxFileSize      = 64 << 20
)

var ErrInvalidSession = errors.New("persisted rehearsal evidence is missing or inconsistent")

// Run is the immutable binding and read-only lifecycle snapshot for one run.
type Run struct {
	Binding  contract.RunBinding
	State    contract.State
	Revision string
	Receipts []contract.Receipt
}

// Load reads the journal at the supplied run directory. It never creates or
// opens a mutating lifecycle handle, and it requires the caller's run ID to
// match the immutable ID stored in the journal.
func Load(root, runID string) (Run, error) {
	var run Run
	if runID == "" {
		return run, ErrInvalidSession
	}
	binding, state, revision, receipts, err := lifecycle.ReadStoredSnapshot(root)
	if err != nil {
		return run, fmt.Errorf("read persisted rehearsal journal: %w", err)
	}
	if binding.RunID != runID || binding.Workspace != root || state == contract.Unknown {
		return run, ErrInvalidSession
	}
	run = Run{Binding: binding, State: state, Revision: revision, Receipts: receipts}
	return run, nil
}

// Verify evaluates only a persisted, journal-bound oracle. The supplied
// oracle's main and peer receipts are discarded and replaced with receipts
// read from the corresponding immutable journals.
func Verify(root, runID string) (evidence.Result, error) {
	main, err := Load(root, runID)
	if err != nil {
		return evidence.Result{}, err
	}
	oraclePath := filepath.Join(root, "evidence", oracleName)
	raw, err := readOwnedFile(root, oraclePath)
	if err != nil {
		return evidence.Result{}, fmt.Errorf("read persisted evidence oracle: %w", err)
	}
	var oracle evidence.Oracle
	if err := contract.DecodeStrict(raw, &oracle); err != nil {
		return evidence.Result{}, fmt.Errorf("decode persisted evidence oracle: %w", err)
	}
	digest := sha256.Sum256(raw)
	oracleDigest := hex.EncodeToString(digest[:])
	verifyReceipt, ok := successfulPhase(main.Receipts, contract.Verify)
	if !ok || verifyReceipt.EvidenceDigests["oracle"] != oracleDigest {
		return evidence.Result{}, fmt.Errorf("%w: oracle digest is not pinned by the successful verify receipt", ErrInvalidSession)
	}
	wantBinding, err := contract.Digest(main.Binding)
	if err != nil {
		return evidence.Result{}, err
	}
	gotBinding, err := contract.Digest(oracle.Binding)
	if err != nil || gotBinding != wantBinding {
		return evidence.Result{}, fmt.Errorf("%w: oracle run binding mismatch", ErrInvalidSession)
	}
	oracle.Binding = main.Binding
	oracle.Receipts = append([]contract.Receipt(nil), main.Receipts...)

	peerBinding := oracle.PeerBinding
	peerWorkspace, ok := main.Binding.Paths["peer_workspace"]
	if !ok || peerWorkspace != peerBinding.Workspace || peerBinding.OwnershipMarker == main.Binding.OwnershipMarker {
		return evidence.Result{}, fmt.Errorf("%w: peer workspace is not independently bound to the main run", ErrInvalidSession)
	}
	peer, err := Load(peerBinding.Workspace, peerBinding.RunID)
	if err != nil {
		return evidence.Result{}, fmt.Errorf("read independent persisted journal: %w", err)
	}
	wantPeer, err := contract.Digest(peer.Binding)
	if err != nil {
		return evidence.Result{}, err
	}
	gotPeer, err := contract.Digest(peerBinding)
	if err != nil || gotPeer != wantPeer {
		return evidence.Result{}, fmt.Errorf("%w: independent run binding mismatch", ErrInvalidSession)
	}
	oracle.PeerBinding = peer.Binding
	oracle.PeerReceipts = append([]contract.Receipt(nil), peer.Receipts...)
	if len(peer.Receipts) == 0 {
		return evidence.Result{SchemaVersion: evidence.Version, Verdict: contract.Inconclusive, Qualification: "pending",
			Reason: "independent persisted journal receipts missing"}, nil
	}

	result := evidence.Evaluate(oracle)
	// The evidence oracle evaluates local consistency only. It cannot qualify
	// a runtime or substitute for Core and operational acceptance gates.
	if result.Verdict == contract.Pass {
		result.Qualification = "evidence_verified"
	}
	return result, nil
}

// WriteVerification atomically persists a derived local evidence verdict in
// the run-owned evidence directory.
func WriteVerification(root string, result evidence.Result) error {
	if result.SchemaVersion != evidence.Version || result.Qualification != "evidence_verified" && result.Qualification != "pending" && result.Qualification != "not_run" {
		return errors.New("invalid local evidence result")
	}
	raw, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return writeEvidenceFiles(root, map[string][]byte{verificationName: raw})
}

// WriteReport derives a redacted report from a fresh journal-backed evaluation
// and writes only report.json and report.md under the run's evidence directory.
func WriteReport(root, runID string) (evidence.Result, error) {
	result, err := Verify(root, runID)
	if err != nil {
		return evidence.Result{}, err
	}
	report, err := evidence.Render(result)
	if err != nil {
		return result, err
	}
	if err := writeEvidenceFiles(root, map[string][]byte{reportJSONName: append(report.JSON, '\n'), reportMDName: report.Markdown}); err != nil {
		return result, err
	}
	return result, nil
}

// WriteReportResult renders and writes only redacted outputs derived from a
// fresh journal-backed result already returned by Verify or VerifyFresh.
func WriteReportResult(root string, result evidence.Result) error {
	if result.SchemaVersion != evidence.Version {
		return errors.New("invalid local evidence result")
	}
	report, err := evidence.Render(result)
	if err != nil {
		return err
	}
	return writeEvidenceFiles(root, map[string][]byte{reportJSONName: append(report.JSON, '\n'), reportMDName: report.Markdown})
}

// Capture verifies the catalog, source, scoped approval and proof summaries
// before opening the mutating journal, then records intent/result around the
// adapter transfer. The raw evidence verifiers remain an explicit trust input.
func Capture(ctx context.Context, request CaptureRequest) (contract.Receipt, error) {
	adapter, err := validateCaptureRequest(ctx, request)
	if err != nil {
		return contract.Receipt{}, err
	}
	root := request.Binding.Workspace
	journalPath := filepath.Join(root, "lifecycle.json")
	_, journalErr := os.Lstat(journalPath)
	if journalErr == nil {
		binding, state, _, receipts, readErr := lifecycle.ReadStoredSnapshot(root)
		if readErr != nil {
			return contract.Receipt{}, fmt.Errorf("read existing capture journal: %w", readErr)
		}
		if !sameBinding(binding, request.Binding) || state != contract.Planned || len(receipts) != 0 {
			return contract.Receipt{}, ErrCaptureJournalRequired
		}
	} else if !errors.Is(journalErr, os.ErrNotExist) {
		return contract.Receipt{}, fmt.Errorf("inspect capture journal path: %w", journalErr)
	} else if err := requireEmptyOrAbsentWorkspace(root); err != nil {
		return contract.Receipt{}, fmt.Errorf("new capture workspace refused: %w", err)
	}
	journal, err := lifecycle.Open(root, request.Binding)
	if err != nil {
		return contract.Receipt{}, err
	}
	defer journal.Close()
	binding, state, _, receipts := journal.Snapshot()
	if !sameBinding(binding, request.Binding) || state != contract.Planned || len(receipts) != 0 {
		return contract.Receipt{}, ErrCaptureJournalRequired
	}
	return journal.Execute(ctx, "frozen_export_copy", contract.Receipt{Phase: contract.Capture}, captureMutationAdapter{adapter: adapter, manifest: request.Manifest, snapshotReader: request.SnapshotReader})
}

func sameBinding(a, b contract.RunBinding) bool {
	da, errA := contract.Digest(a)
	db, errB := contract.Digest(b)
	return errA == nil && errB == nil && da == db
}

func requireEmptyOrAbsentWorkspace(root string) error {
	info, err := os.Lstat(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("workspace must be absent or a real directory")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != ".lifecycle.lock" {
			return errors.New("refusing to initialize a nonempty workspace without a journal")
		}
	}
	return nil
}

type captureMutationAdapter struct {
	adapter        contract.CaptureAdapter
	manifest       contract.SourceManifest
	snapshotReader SnapshotReader
}

func (a captureMutationAdapter) Execute(ctx context.Context, binding contract.RunBinding, operation string) (contract.Receipt, error) {
	if operation != "frozen_export_copy" {
		return contract.Receipt{}, errors.New("unsupported capture operation")
	}
	receipt, err := a.adapter.Capture(ctx, binding, a.manifest)
	if err != nil {
		return receipt, err
	}
	if receipt.State != contract.Succeeded || a.snapshotReader == nil {
		return receipt, nil
	}
	digest, err := captureTopologySnapshot(ctx, binding, a.manifest, a.snapshotReader)
	if err != nil {
		return receipt, err
	}
	if receipt.EvidenceDigests == nil {
		receipt.EvidenceDigests = map[string]string{}
	}
	receipt.EvidenceDigests["topology.before"] = digest
	return receipt, nil
}

func validateCaptureRequest(ctx context.Context, request CaptureRequest) (capture.Adapter, error) {
	binding := request.Binding
	if ctx == nil || request.Verifier == nil {
		return capture.Adapter{}, ErrCaptureVerifierUnavailable
	}
	verifier, ok := request.Verifier.(capture.ProofVerifier)
	if !ok {
		return capture.Adapter{}, fmt.Errorf("%w: incompatible API", ErrCaptureVerifierUnavailable)
	}
	if err := contract.ValidateBinding(binding); err != nil {
		return capture.Adapter{}, err
	}
	if binding.Paths["export"] == "" || binding.Paths["source"] == "" {
		return capture.Adapter{}, errors.New("bound export and source paths are required")
	}
	for _, item := range []struct {
		name string
		doc  contract.SignedDocument
	}{{"catalog", request.CatalogDocument}, {"recovery_artifact", request.ArtifactDocument}, {"source_manifest", request.SourceDocument}, {"capture_approval", request.Approval}} {
		if len(item.doc.Payload) == 0 || binding.InputDigests[item.name] != contract.PayloadDigest(item.doc.Payload) {
			return capture.Adapter{}, fmt.Errorf("%s payload is absent or differs from frozen run digest", item.name)
		}
	}
	catalogPolicyBinding, err := contract.Digest(request.CatalogPolicy.Verification.Binding)
	if err != nil || catalogPolicyBinding != mustBindingDigest(binding) || request.CatalogPolicy.Scope != catalog.CatalogScope {
		return capture.Adapter{}, errors.New("catalog trust policy does not match the immutable run")
	}
	approvedCatalog, err := catalog.VerifyCatalog(request.CatalogDocument, request.CatalogPolicy)
	if err != nil {
		return capture.Adapter{}, fmt.Errorf("verify signed catalog: %w", err)
	}
	artifactPolicyBinding, err := contract.Digest(request.ArtifactPolicy.Verification.Binding)
	if err != nil || artifactPolicyBinding != mustBindingDigest(binding) || request.ArtifactPolicy.Scope != catalog.ArtifactScope {
		return capture.Adapter{}, errors.New("artifact trust policy does not match the immutable run")
	}
	artifact, err := catalog.VerifyArtifact(request.ArtifactDocument, request.ArtifactPolicy, approvedCatalog)
	if err != nil {
		return capture.Adapter{}, fmt.Errorf("verify signed recovery artifact: %w", err)
	}
	policy, err := capture.PolicyFromVerifiedArtifact(artifact, binding, request.MaxBytes, request.ReserveBytes)
	if err != nil {
		return capture.Adapter{}, err
	}
	sourcePolicy := request.SourcePolicy
	if sourcePolicy.Kind != "source_manifest" || sourcePolicy.Scope != "capture" || sourcePolicy.Role != "archive_owner" || mustBindingDigest(sourcePolicy.Binding) != mustBindingDigest(binding) {
		return capture.Adapter{}, errors.New("source trust policy must be bound to source_manifest/capture/archive_owner")
	}
	manifest, err := input.VerifySourceManifest(request.SourceDocument, sourcePolicy)
	if err != nil {
		return capture.Adapter{}, fmt.Errorf("verify signed source manifest: %w", err)
	}
	if !sameManifest(manifest, request.Manifest) {
		return capture.Adapter{}, errors.New("typed source manifest differs from signed source document")
	}
	approvalPolicy := request.ApprovalPolicy
	if approvalPolicy.Kind != "approval" || approvalPolicy.Scope != "capture" || approvalPolicy.Role != "operator" || mustBindingDigest(approvalPolicy.Binding) != mustBindingDigest(binding) {
		return capture.Adapter{}, errors.New("approval trust policy must be bound to approval/capture/operator")
	}
	approvalPolicy.Binding.InputDigests = cloneInputDigests(binding.InputDigests)
	approvalPolicy.Binding.InputDigests["approval"] = contract.PayloadDigest(request.Approval.Payload)
	if _, err := input.VerifyDocument(request.Approval, approvalPolicy); err != nil {
		return capture.Adapter{}, fmt.Errorf("verify scoped capture approval: %w", err)
	}
	for name, raw := range map[string][]byte{"snapshot_freeze": request.FreezePayload, "layout_proof": request.LayoutPayload, "inventory_receipt": request.InventoryPayload, "offline_reader": request.OfflineReader} {
		if len(raw) == 0 || binding.InputDigests[name] != contract.PayloadDigest(raw) {
			return capture.Adapter{}, fmt.Errorf("%s proof is absent or differs from frozen run digest", name)
		}
	}
	if len(request.WitnessPayloads) != 2 {
		return capture.Adapter{}, errors.New("exactly two witness proofs are required")
	}
	for i, raw := range request.WitnessPayloads {
		key := fmt.Sprintf("witness_%d", i+1)
		if len(raw) == 0 || binding.InputDigests[key] != contract.PayloadDigest(raw) {
			return capture.Adapter{}, fmt.Errorf("%s proof is absent or differs from frozen run digest", key)
		}
	}
	if err := verifyCaptureProofSummaries(ctx, verifier, binding, manifest, request); err != nil {
		return capture.Adapter{}, err
	}
	return capture.Adapter{Root: binding.Paths["export"], Destination: binding.Paths["source"], Policy: policy,
		SourcePayload: append([]byte(nil), request.SourceDocument.Payload...), SourceDocument: request.SourceDocument,
		SourcePolicy: sourcePolicy, Approval: request.Approval, ApprovalPolicy: request.ApprovalPolicy,
		FreezePayload: append([]byte(nil), request.FreezePayload...), LayoutPayload: append([]byte(nil), request.LayoutPayload...),
		InventoryPayload: append([]byte(nil), request.InventoryPayload...), WitnessPayloads: clonePayloads(request.WitnessPayloads),
		OfflineReaderPayload: append([]byte(nil), request.OfflineReader...), Verifier: verifier}, nil
}

func verifyCaptureProofSummaries(ctx context.Context, verifier capture.ProofVerifier, binding contract.RunBinding, manifest contract.SourceManifest, request CaptureRequest) error {
	digest, err := contract.Digest(binding)
	if err != nil {
		return err
	}
	gotSnapshot, err := verifier.VerifySnapshotInputs(ctx, binding, manifest, request.FreezePayload, request.LayoutPayload, request.InventoryPayload)
	if err != nil {
		return fmt.Errorf("verify frozen snapshot inputs: %w", err)
	}
	if !proofBindingMatches(gotSnapshot.VerificationBinding, binding, request.FreezePayload, digest) || gotSnapshot.FreezePayloadSHA256 != contract.PayloadDigest(request.FreezePayload) || gotSnapshot.LayoutPayloadSHA256 != contract.PayloadDigest(request.LayoutPayload) || gotSnapshot.InventoryPayloadSHA256 != contract.PayloadDigest(request.InventoryPayload) || gotSnapshot.SnapshotID != manifest.SnapshotID || gotSnapshot.Backend != manifest.Backend || gotSnapshot.Layout != manifest.Layout || gotSnapshot.BackendVersion != manifest.BackendVersion || !gotSnapshot.Frozen {
		return errors.New("snapshot proof verifier result does not bind the exact frozen manifest")
	}
	inventoryDigest, err := contract.Digest(manifest.Files)
	if err != nil || gotSnapshot.InventorySHA256 != inventoryDigest {
		return errors.New("snapshot proof inventory does not match signed source inventory")
	}
	var first capture.WitnessVerification
	sources := map[string]bool{}
	for _, raw := range request.WitnessPayloads {
		got, err := verifier.VerifyWitness(ctx, binding, raw)
		if err != nil {
			return fmt.Errorf("verify independent witness: %w", err)
		}
		if !proofBindingMatches(got.VerificationBinding, binding, raw, digest) || got.SourceIdentity == "" || sources[got.SourceIdentity] || got.BlockID != binding.BlockID || got.BlockHeight != binding.Heights.Blockstore || got.AppHash != binding.AppHash || got.AppHashHeight != binding.Heights.App || !got.ValidatorSetComplete || !contract.IsDigest(got.ValidatorSetSHA256) || got.TotalVotingPower == 0 || got.SignedVotingPower > got.TotalVotingPower || !strictlyAboveTwoThirds(got.SignedVotingPower, got.TotalVotingPower) || !uniqueStrings(got.SignerIDs) {
			return errors.New("witness proof does not establish independent source and complete H/H-1 quorum evidence")
		}
		if len(sources) > 0 && (got.ValidatorSetSHA256 != first.ValidatorSetSHA256 || got.TotalVotingPower != first.TotalVotingPower) {
			return errors.New("independent witnesses disagree on validator set")
		}
		sources[got.SourceIdentity] = true
		if len(sources) == 1 {
			first = got
		}
	}
	offline, err := verifier.VerifyOfflineReader(ctx, binding, request.OfflineReader)
	if err != nil {
		return fmt.Errorf("verify offline consensus reader: %w", err)
	}
	if !proofBindingMatches(offline.VerificationBinding, binding, request.OfflineReader, digest) || binding.Heights.Consensus == nil || offline.ConsensusHeight != *binding.Heights.Consensus || offline.SnapshotID != manifest.SnapshotID {
		return errors.New("offline reader does not bind frozen snapshot consensus height")
	}
	return nil
}

func proofBindingMatches(got capture.VerificationBinding, binding contract.RunBinding, raw []byte, digest string) bool {
	return got.RunID == binding.RunID && got.ChainID == binding.ChainID && got.GenesisSHA256 == binding.GenesisSHA256 && got.BindingDigest == digest && got.PayloadSHA256 == contract.PayloadDigest(raw)
}

func strictlyAboveTwoThirds(signed, total uint64) bool {
	if total == 0 || signed > total {
		return false
	}
	threshold := 2*(total/3) + (2*(total%3))/3
	return signed > threshold
}

func uniqueStrings(values []string) bool {
	if len(values) == 0 {
		return false
	}
	seen := map[string]bool{}
	for _, value := range values {
		if value == "" || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func mustBindingDigest(binding contract.RunBinding) string {
	digest, _ := contract.Digest(binding)
	return digest
}

func sameManifest(a, b contract.SourceManifest) bool {
	da, _ := contract.Digest(a)
	db, _ := contract.Digest(b)
	return da == db
}

func clonePayloads(values [][]byte) [][]byte {
	out := make([][]byte, len(values))
	for i := range values {
		out[i] = append([]byte(nil), values[i]...)
	}
	return out
}

func cloneInputDigests(values map[string]string) map[string]string {
	out := make(map[string]string, len(values)+1)
	for k, v := range values {
		out[k] = v
	}
	return out
}

func successfulPhase(receipts []contract.Receipt, phase contract.Phase) (contract.Receipt, bool) {
	var found contract.Receipt
	count := 0
	for _, receipt := range receipts {
		if receipt.Phase == phase && receipt.Operation != "" && receipt.State == contract.Succeeded {
			found = receipt
			count++
		}
	}
	return found, count == 1
}

func readOwnedFile(root, fullPath string) ([]byte, error) {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root || filepath.Dir(fullPath) != filepath.Join(root, "evidence") {
		return nil, errors.New("unsafe evidence path")
	}
	rootDir, err := openOwnedRoot(root)
	if err != nil {
		return nil, err
	}
	defer rootDir.Close()
	evidenceDir, err := openEvidenceRoot(rootDir, false)
	if err != nil {
		return nil, err
	}
	defer evidenceDir.Close()
	name := filepath.Base(fullPath)
	before, err := evidenceDir.Lstat(name)
	if err != nil || !before.Mode().IsRegular() || before.Mode()&os.ModeSymlink != 0 || before.Mode().Perm() != 0600 || !singleLink(before) || !ownedByCurrentUser(before) || before.Size() > maxFileSize {
		return nil, errors.New("evidence input must be a private regular file")
	}
	file, err := evidenceDir.OpenFile(name, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(before, opened) {
		return nil, errors.New("evidence input identity changed")
	}
	data, err := io.ReadAll(io.LimitReader(file, maxFileSize+1))
	if err != nil || len(data) > maxFileSize {
		return nil, errors.New("evidence input exceeds size limit")
	}
	after, err := file.Stat()
	if err != nil || !os.SameFile(opened, after) || after.Size() != opened.Size() || after.ModTime() != opened.ModTime() || len(data) != int(after.Size()) {
		return nil, errors.New("evidence input changed while reading")
	}
	return data, nil
}

func writeEvidenceFiles(root string, files map[string][]byte) error {
	if len(files) == 0 {
		return errors.New("no evidence outputs requested")
	}
	for name, data := range files {
		if len(data) > maxFileSize || filepath.Base(name) != name || strings.ContainsAny(name, `/\\`) {
			return errors.New("unsafe evidence output")
		}
	}
	rootDir, err := openOwnedRoot(root)
	if err != nil {
		return err
	}
	defer rootDir.Close()
	evidenceDir, err := openEvidenceRoot(rootDir, true)
	if err != nil {
		return err
	}
	defer evidenceDir.Close()
	type stagedFile struct{ temp, target string }
	staged := make([]stagedFile, 0, len(files))
	cleanup := func() {
		for _, item := range staged {
			_ = evidenceDir.Remove(item.temp)
		}
	}
	for name := range files {
		if existing, err := evidenceDir.Lstat(name); err == nil {
			if !existing.Mode().IsRegular() || existing.Mode()&os.ModeSymlink != 0 || existing.Mode().Perm() != 0600 || !singleLink(existing) || !ownedByCurrentUser(existing) {
				cleanup()
				return errors.New("unsafe existing evidence output")
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			cleanup()
			return err
		}
	}
	for name, data := range files {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			cleanup()
			return err
		}
		temp := ".evidence-" + hex.EncodeToString(random[:])
		file, err := evidenceDir.OpenFile(temp, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0600)
		if err != nil {
			cleanup()
			return err
		}
		staged = append(staged, stagedFile{temp: temp, target: name})
		if _, err := file.Write(data); err != nil {
			file.Close()
			cleanup()
			return err
		}
		if err := file.Sync(); err != nil {
			file.Close()
			cleanup()
			return err
		}
		if err := file.Close(); err != nil {
			cleanup()
			return err
		}
	}
	for _, item := range staged {
		if err := evidenceDir.Rename(item.temp, item.target); err != nil {
			cleanup()
			return err
		}
	}
	dir, err := evidenceDir.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func openOwnedRoot(path string) (*os.Root, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == string(filepath.Separator) {
		return nil, errors.New("unsafe run directory")
	}
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("run path contains a non-directory or symlink")
		}
		if current == filepath.Dir(current) {
			break
		}
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Perm() != 0700 || !ownedByCurrentUser(info) {
		return nil, errors.New("run directory is not privately owned")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	pinned, err := root.Stat(".")
	if err != nil || !os.SameFile(info, pinned) {
		root.Close()
		return nil, errors.New("run directory identity changed")
	}
	return root, nil
}

func validateEvidenceDir(root *os.Root, create bool) error {
	info, err := root.Lstat("evidence")
	if errors.Is(err, os.ErrNotExist) && create {
		if err := root.Mkdir("evidence", 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		info, err = root.Lstat("evidence")
	}
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 || !ownedByCurrentUser(info) {
		return errors.New("evidence directory must be privately owned")
	}
	return nil
}

func openEvidenceRoot(root *os.Root, create bool) (*os.Root, error) {
	if err := validateEvidenceDir(root, create); err != nil {
		return nil, err
	}
	before, err := root.Lstat("evidence")
	if err != nil {
		return nil, err
	}
	dir, err := root.OpenRoot("evidence")
	if err != nil {
		return nil, err
	}
	pinned, err := dir.Stat(".")
	if err != nil || !os.SameFile(before, pinned) {
		dir.Close()
		return nil, errors.New("evidence directory identity changed")
	}
	return dir, nil
}

func singleLink(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Nlink == 1
}

func ownedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}
