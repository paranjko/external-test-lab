package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
	"github.com/spf13/cobra"
)

type RehearsalDependencies struct {
	TrustRoots            []input.TrustRoot
	Revocations           input.RevocationSnapshot
	Clock                 func() time.Time
	CaptureProofVerifier  any
	CaptureMaxBytes       int64
	CaptureReserveBytes   int64
	CaptureSnapshotReader session.SnapshotReader
	StageAdapter          session.StageAdapter
	RunAdapter            session.RunAdapter
}

type rehearsalOptions struct {
	apply            bool
	asJSON           bool
	workspace        string
	runID            string
	bindingPath      string
	sourcePath       string
	catalogPath      string
	artifactPath     string
	peerCatalogPath  string
	peerArtifactPath string
	approvalPath     string
	proofsPath       string
	resume           string
}

type captureEvidencePaths struct {
	Freeze        string   `json:"freeze"`
	Layout        string   `json:"layout"`
	Inventory     string   `json:"inventory"`
	Witnesses     []string `json:"witnesses"`
	OfflineReader string   `json:"offline_reader"`
}

func newRehearsalCommand(dependencies RehearsalDependencies) *cobra.Command {
	options := rehearsalOptions{}
	command := &cobra.Command{
		Use:           "recover <scenario> [phase]",
		Short:         "preview or validate a local recovery rehearsal",
		Args:          cobra.RangeArgs(1, 2),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			phase := contract.Inspect
			if len(args) == 2 {
				phase = contract.Phase(args[1])
			}
			outcome := rehearsalOutcome(phase)
			if options.bindingPath != "" {
				if binding, err := readBinding(options.bindingPath); err == nil {
					outcome.RunID = binding.RunID
				}
			}
			if options.resume != "" && (options.runID == "" || options.resume != options.runID) {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "resume_run_id_mismatch", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if args[0] != contract.Scenario {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "unsupported_scenario", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if !contract.ValidPhase(phase) {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "unsupported_phase", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if phase == contract.Verify || phase == contract.Report {
				if options.apply {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "apply_not_supported_for_read_only_phase", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if options.runID == "" || options.workspace == "" || options.resume != "" && options.resume != options.runID {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "persisted_run_identity_required", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				run, err := session.Load(options.workspace, options.runID)
				if err != nil {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "persisted_run_unavailable", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if options.workspace != run.Binding.Workspace {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "persisted_run_binding_mismatch", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if options.bindingPath != "" {
					repeatedBinding, err := readBinding(options.bindingPath)
					want, wantErr := contract.Digest(run.Binding)
					got, gotErr := contract.Digest(repeatedBinding)
					if err != nil || wantErr != nil || gotErr != nil || got != want {
						outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "repeated_binding_mismatch", 2
						return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
					}
				}
				if err := validateRepeatedInputs(options, run.Binding, dependencies); err != nil {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "repeated_input_mismatch", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				var result evidence.Result
				var verifyReceipt *contract.Receipt
				for _, receipt := range run.Receipts {
					if receipt.Phase == contract.Verify {
						copy := receipt
						verifyReceipt = &copy
					}
				}
				if verifyReceipt != nil && verifyReceipt.EvidenceDigests["fresh_result"] == "" {
					result, err = session.Verify(options.workspace, options.runID)
				} else {
					if options.catalogPath == "" || options.artifactPath == "" || options.peerCatalogPath == "" || options.peerArtifactPath == "" {
						outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "signed_verification_inputs_required", 2
						return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
					}
					mainCatalog, mainCatalogErr := readEnvelope(options.catalogPath)
					mainArtifact, mainArtifactErr := readEnvelope(options.artifactPath)
					peerCatalog, peerCatalogErr := readEnvelope(options.peerCatalogPath)
					peerArtifact, peerArtifactErr := readEnvelope(options.peerArtifactPath)
					if mainCatalogErr != nil || mainArtifactErr != nil || peerCatalogErr != nil || peerArtifactErr != nil {
						outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "signed_verification_inputs_unavailable", 2
						return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
					}
					result, err = session.VerifyFresh(cmd.Context(), options.workspace, options.runID, mainCatalog, mainArtifact, peerCatalog, peerArtifact,
						dependencies.TrustRoots, dependencies.Revocations, dependencies.Clock)
				}
				if err != nil {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "persisted_evidence_refused", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if err := session.WriteVerification(options.workspace, result); err != nil {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "evidence_write_refused", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if phase == contract.Report {
					if err := session.WriteReportResult(options.workspace, result); err != nil {
						outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "report_write_refused", 2
						return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
					}
				}
				outcome.RunID = run.Binding.RunID
				outcome.Mode, outcome.Mutation = "persisted_evidence", "evidence_only"
				outcome.Status, outcome.Code, outcome.ExitCode = "succeeded", "evidence_verified", 0
				if result.Verdict != contract.Pass {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "evidence_not_pass", 2
				}
				outcome.Verdict, outcome.Qualification = result.Verdict, result.Qualification
				outcome.Receipts = result.Receipts
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if phase == contract.Stage || phase == contract.Run {
				return executeRehearsalPhase(cmd, phase, options, dependencies)
			}
			if phase != contract.Inspect && phase != contract.Capture {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "phase_adapter_unavailable", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if phase == contract.Inspect && options.apply {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "apply_not_supported_for_inspect", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if phase == contract.Inspect {
				if options.bindingPath == "" && options.sourcePath == "" && options.artifactPath == "" {
					outcome.Code = "offline_preview_only"
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				if err := validateInspectInputs(options, dependencies); err != nil {
					outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "input_validation_refused", 2
					return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
				}
				outcome.Code = "offline_inputs_validated"
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if !options.apply || options.runID == "" || options.workspace == "" || options.bindingPath == "" || options.sourcePath == "" || options.catalogPath == "" || options.artifactPath == "" || options.approvalPath == "" || options.proofsPath == "" {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_inputs_incomplete", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if dependencies.CaptureProofVerifier == nil {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_proof_verifier_unavailable", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			request, err := validateCaptureInputs(options, dependencies)
			if err != nil {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_input_validation_refused", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			outcome.RunID = request.Binding.RunID
			receipt, err := session.Capture(cmd.Context(), request)
			if err != nil {
				switch {
				case errors.Is(err, session.ErrCaptureJournalRequired):
					outcome.Code = "capture_run_journal_required"
				case errors.Is(err, session.ErrCaptureVerifierUnavailable):
					outcome.Code = "capture_proof_verifier_unavailable"
				default:
					outcome.Code = "capture_dispatch_refused"
				}
				outcome.Status, outcome.ExitCode = "blocked", 2
				if receipt.Operation != "" {
					outcome.Receipts = []contract.Receipt{receipt}
				}
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if err := contract.ValidateReceipt(receipt, request.Binding); err != nil {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_adapter_contract_violation", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if err := contract.ValidateSchema("receipt", receipt); err != nil {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_receipt_schema_violation", 2
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			if receipt.State != contract.Succeeded {
				outcome.Status, outcome.Code, outcome.ExitCode = "blocked", "capture_not_succeeded", 2
				outcome.Receipts = []contract.Receipt{receipt}
				return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
			}
			outcome.Mode, outcome.Mutation = "local_capture", "owned_workspace"
			outcome.Status, outcome.Code, outcome.ExitCode = "succeeded", "capture_succeeded", 0
			outcome.Qualification = "not_run"
			outcome.Receipts = []contract.Receipt{receipt}
			return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
		},
	}
	command.Flags().BoolVar(&options.apply, "apply", false, "explicitly request a supported local phase")
	command.Flags().BoolVar(&options.asJSON, "json", true, "emit a structured outcome")
	command.Flags().StringVar(&options.workspace, "workspace", "", "absolute local rehearsal workspace")
	command.Flags().StringVar(&options.runID, "run-id", "", "immutable rehearsal run ID")
	command.Flags().StringVar(&options.bindingPath, "binding", "", "local run binding JSON")
	command.Flags().StringVar(&options.sourcePath, "source-manifest", "", "signed frozen source manifest envelope")
	command.Flags().StringVar(&options.catalogPath, "catalog", "", "signed recovery catalog envelope")
	command.Flags().StringVar(&options.artifactPath, "recovery-artifact", "", "signed recovery artifact envelope")
	command.Flags().StringVar(&options.peerCatalogPath, "peer-catalog", "", "signed independent recovery catalog envelope for first verification")
	command.Flags().StringVar(&options.peerArtifactPath, "peer-recovery-artifact", "", "signed independent recovery artifact envelope for first verification")
	command.Flags().StringVar(&options.approvalPath, "capture-approval", "", "operator-signed capture approval envelope")
	command.Flags().StringVar(&options.proofsPath, "capture-evidence", "", "JSON file naming frozen snapshot, witness and offline-reader proof files")
	command.Flags().StringVar(&options.resume, "resume", "", "resume only the matching immutable run ID")
	return command
}

func rehearsalOutcome(phase contract.Phase) contract.Outcome {
	return contract.Outcome{SchemaVersion: contract.Version, Scenario: contract.Scenario, Phase: phase,
		Mode: "preview", Status: "planned", Code: "offline_preview_only", Mutation: "none",
		Qualification: "not_run", Receipts: []contract.Receipt{}, ExitCode: 0}
}

func renderRehearsal(writer io.Writer, outcome contract.Outcome, asJSON bool) error {
	if asJSON {
		encoder := json.NewEncoder(writer)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(outcome); err != nil {
			return err
		}
	} else if _, err := fmt.Fprintf(writer, "%s %s (%s)\n", outcome.Status, outcome.Scenario, outcome.Code); err != nil {
		return err
	}
	if outcome.ExitCode != 0 {
		return &ExitError{Code: outcome.ExitCode, Err: errors.New(outcome.Code)}
	}
	return nil
}

func validateInspectInputs(options rehearsalOptions, dependencies RehearsalDependencies) error {
	if options.bindingPath == "" {
		return fmt.Errorf("run binding required to validate signed inputs")
	}
	binding, err := readBinding(options.bindingPath)
	if err != nil {
		return err
	}
	if options.runID != "" && options.runID != binding.RunID || options.workspace != "" && options.workspace != binding.Workspace {
		return fmt.Errorf("CLI binding mismatch")
	}
	if options.sourcePath != "" {
		document, _, err := readAndVerify(options.sourcePath, "source_manifest", "capture", "archive_owner", binding, dependencies)
		if err != nil {
			return err
		}
		if _, err := input.VerifySourceManifest(document, verificationPolicy("source_manifest", "capture", "archive_owner", binding, dependencies)); err != nil {
			return err
		}
	}
	var verifiedCatalog catalog.Catalog
	if options.catalogPath != "" {
		doc, err := readEnvelope(options.catalogPath)
		if err != nil {
			return err
		}
		verifiedCatalog, err = catalog.VerifyCatalog(doc, catalog.Policy{Scope: catalog.CatalogScope,
			Verification: verificationPolicy(catalog.CatalogKind, catalog.CatalogScope, "catalog", binding, dependencies)})
		if err != nil {
			return err
		}
	}
	if options.artifactPath != "" {
		if verifiedCatalog.Metadata.Kind == "" {
			return fmt.Errorf("signed catalog is required to validate recovery artifact")
		}
		doc, err := readEnvelope(options.artifactPath)
		if err != nil {
			return err
		}
		if _, err := catalog.VerifyArtifact(doc, catalog.Policy{Scope: catalog.ArtifactScope,
			Verification: verificationPolicy(catalog.ArtifactKind, catalog.ArtifactScope, "core", binding, dependencies)}, verifiedCatalog); err != nil {
			return err
		}
	}
	return nil
}

func validateCaptureInputs(options rehearsalOptions, dependencies RehearsalDependencies) (session.CaptureRequest, error) {
	var request session.CaptureRequest
	binding, err := readBinding(options.bindingPath)
	if err != nil {
		return request, err
	}
	if options.runID != binding.RunID || options.workspace != binding.Workspace {
		return request, fmt.Errorf("CLI binding mismatch")
	}
	document, _, err := readAndVerify(options.sourcePath, "source_manifest", "capture", "archive_owner", binding, dependencies)
	if err != nil {
		return request, err
	}
	manifest, err := input.DecodeSourceManifest(document)
	if err != nil {
		return request, err
	}
	catalogDocument, err := readEnvelope(options.catalogPath)
	if err != nil {
		return request, err
	}
	if binding.InputDigests[catalog.CatalogKind] != contract.PayloadDigest(catalogDocument.Payload) {
		return request, fmt.Errorf("signed catalog differs from frozen run input")
	}
	catalogPolicy := catalog.Policy{Scope: catalog.CatalogScope, Verification: verificationPolicy(catalog.CatalogKind, catalog.CatalogScope, "catalog", binding, dependencies)}
	verifiedCatalog, err := catalog.VerifyCatalog(catalogDocument, catalogPolicy)
	if err != nil {
		return request, fmt.Errorf("verify signed catalog: %w", err)
	}
	artifactDocument, err := readEnvelope(options.artifactPath)
	if err != nil {
		return request, err
	}
	if binding.InputDigests[catalog.ArtifactKind] != contract.PayloadDigest(artifactDocument.Payload) {
		return request, fmt.Errorf("signed recovery artifact differs from frozen run input")
	}
	artifactPolicy := catalog.Policy{Scope: catalog.ArtifactScope, Verification: verificationPolicy(catalog.ArtifactKind, catalog.ArtifactScope, "core", binding, dependencies)}
	artifact, err := catalog.VerifyArtifact(artifactDocument, artifactPolicy, verifiedCatalog)
	if err != nil {
		return request, fmt.Errorf("verify signed recovery artifact: %w", err)
	}
	approval, _, err := readAndVerify(options.approvalPath, "approval", "capture", "operator", binding, dependencies)
	if err != nil {
		return request, err
	}
	if _, err := input.VerifySourceManifest(document, verificationPolicy("source_manifest", "capture", "archive_owner", binding, dependencies)); err != nil {
		return request, err
	}
	proofs, err := readCaptureEvidence(options.proofsPath)
	if err != nil {
		return request, err
	}
	proofPayloads := map[string][]byte{}
	for _, item := range []struct{ key, path string }{{"snapshot_freeze", proofs.Freeze}, {"layout_proof", proofs.Layout}, {"inventory_receipt", proofs.Inventory}, {"offline_reader", proofs.OfflineReader}} {
		payload, err := readLocalJSON(item.path)
		if err != nil {
			return request, fmt.Errorf("read %s proof: %w", item.key, err)
		}
		if binding.InputDigests[item.key] != contract.PayloadDigest(payload) {
			return request, fmt.Errorf("%s proof differs from frozen run input", item.key)
		}
		proofPayloads[item.key] = payload
	}
	if len(proofs.Witnesses) != 2 {
		return request, fmt.Errorf("capture evidence requires exactly two witness proof files")
	}
	witnessPayloads := make([][]byte, 2)
	for i, path := range proofs.Witnesses {
		payload, err := readLocalJSON(path)
		if err != nil {
			return request, fmt.Errorf("read witness_%d proof: %w", i+1, err)
		}
		key := fmt.Sprintf("witness_%d", i+1)
		if binding.InputDigests[key] != contract.PayloadDigest(payload) {
			return request, fmt.Errorf("%s proof differs from frozen run input", key)
		}
		witnessPayloads[i] = payload
	}
	maxBytes, err := captureQuota(artifact.Files, dependencies.CaptureMaxBytes)
	if err != nil {
		return request, err
	}
	approvalPolicy := verificationPolicy("approval", "capture", "operator", binding, dependencies)
	approvalPolicy.Binding = binding
	request = session.CaptureRequest{Binding: binding, CatalogDocument: catalogDocument, CatalogPolicy: catalogPolicy,
		ArtifactDocument: artifactDocument, ArtifactPolicy: artifactPolicy, SourceDocument: document,
		SourcePolicy: verificationPolicy("source_manifest", "capture", "archive_owner", binding, dependencies),
		Approval:     approval, ApprovalPolicy: approvalPolicy,
		Manifest: manifest, FreezePayload: proofPayloads["snapshot_freeze"], LayoutPayload: proofPayloads["layout_proof"],
		InventoryPayload: proofPayloads["inventory_receipt"], WitnessPayloads: witnessPayloads,
		OfflineReader: proofPayloads["offline_reader"], Verifier: dependencies.CaptureProofVerifier,
		SnapshotReader: dependencies.CaptureSnapshotReader,
		MaxBytes:       maxBytes, ReserveBytes: dependencies.CaptureReserveBytes}
	return request, nil
}

func captureQuota(files []catalog.ArtifactFile, configured int64) (int64, error) {
	if configured > 0 {
		return configured, nil
	}
	const maxInt64 = int64(^uint64(0) >> 1)
	var total int64
	for _, file := range files {
		if file.Size < 0 || file.Size > maxInt64-total {
			return 0, fmt.Errorf("signed artifact file sizes exceed capture quota range")
		}
		total += file.Size
	}
	if total == 0 {
		total = 1
	}
	return total, nil
}

func validateRepeatedInputs(options rehearsalOptions, binding contract.RunBinding, dependencies RehearsalDependencies) error {
	for _, item := range []struct {
		path, kind, role string
	}{{options.sourcePath, "source_manifest", "archive_owner"}, {options.approvalPath, "approval", "operator"}} {
		if item.path == "" {
			continue
		}
		document, _, err := readAndVerify(item.path, item.kind, "capture", item.role, binding, dependencies)
		digestKey := item.kind
		if item.kind == "approval" {
			digestKey = "capture_approval"
		}
		if err != nil || binding.InputDigests[digestKey] != contract.PayloadDigest(document.Payload) {
			return fmt.Errorf("repeated %s does not match frozen run input", item.kind)
		}
		if item.kind == "source_manifest" {
			if _, err := input.VerifySourceManifest(document, verificationPolicy(item.kind, "capture", item.role, binding, dependencies)); err != nil {
				return err
			}
		}
	}
	if options.catalogPath != "" {
		doc, err := readEnvelope(options.catalogPath)
		if err != nil || binding.InputDigests[catalog.CatalogKind] != contract.PayloadDigest(doc.Payload) {
			return fmt.Errorf("repeated catalog differs from frozen run input")
		}
		if _, err := catalog.VerifyCatalog(doc, catalog.Policy{Scope: catalog.CatalogScope, Verification: verificationPolicy(catalog.CatalogKind, catalog.CatalogScope, "catalog", binding, dependencies)}); err != nil {
			return err
		}
	}
	if options.artifactPath != "" {
		if options.catalogPath == "" {
			return fmt.Errorf("repeated artifact requires its signed catalog")
		}
		catalogDoc, err := readEnvelope(options.catalogPath)
		if err != nil {
			return err
		}
		approvedCatalog, err := catalog.VerifyCatalog(catalogDoc, catalog.Policy{Scope: catalog.CatalogScope, Verification: verificationPolicy(catalog.CatalogKind, catalog.CatalogScope, "catalog", binding, dependencies)})
		if err != nil {
			return err
		}
		artifactDoc, err := readEnvelope(options.artifactPath)
		if err != nil || binding.InputDigests[catalog.ArtifactKind] != contract.PayloadDigest(artifactDoc.Payload) {
			return fmt.Errorf("repeated artifact differs from frozen run input")
		}
		if _, err := catalog.VerifyArtifact(artifactDoc, catalog.Policy{Scope: catalog.ArtifactScope, Verification: verificationPolicy(catalog.ArtifactKind, catalog.ArtifactScope, "core", binding, dependencies)}, approvedCatalog); err != nil {
			return err
		}
	}
	if options.proofsPath != "" {
		proofs, err := readCaptureEvidence(options.proofsPath)
		if err != nil {
			return err
		}
		for _, item := range []struct{ key, path string }{{"snapshot_freeze", proofs.Freeze}, {"layout_proof", proofs.Layout}, {"inventory_receipt", proofs.Inventory}, {"offline_reader", proofs.OfflineReader}} {
			payload, err := readLocalJSON(item.path)
			if err != nil || binding.InputDigests[item.key] != contract.PayloadDigest(payload) {
				return fmt.Errorf("repeated %s proof differs from frozen run input", item.key)
			}
		}
		if len(proofs.Witnesses) != 2 {
			return fmt.Errorf("repeated witness inputs are incomplete")
		}
		for i, path := range proofs.Witnesses {
			payload, err := readLocalJSON(path)
			key := fmt.Sprintf("witness_%d", i+1)
			if err != nil || binding.InputDigests[key] != contract.PayloadDigest(payload) {
				return fmt.Errorf("repeated %s proof differs from frozen run input", key)
			}
		}
	}
	return nil
}

func readEnvelope(path string) (contract.SignedDocument, error) {
	raw, err := readLocalJSON(path)
	if err != nil {
		return contract.SignedDocument{}, err
	}
	return catalog.DecodeEnvelope(raw)
}

func readCaptureEvidence(path string) (captureEvidencePaths, error) {
	var paths captureEvidencePaths
	raw, err := readLocalJSON(path)
	if err != nil {
		return paths, err
	}
	if err := contract.DecodeStrict(raw, &paths); err != nil {
		return paths, err
	}
	if paths.Freeze == "" || paths.Layout == "" || paths.Inventory == "" || paths.OfflineReader == "" || len(paths.Witnesses) != 2 {
		return paths, fmt.Errorf("capture evidence must name freeze, layout, inventory, two witnesses, and offline reader")
	}
	for _, path := range append([]string{paths.Freeze, paths.Layout, paths.Inventory, paths.OfflineReader}, paths.Witnesses...) {
		if path == "" || !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return paths, fmt.Errorf("capture proof paths must be clean absolute paths")
		}
	}
	return paths, nil
}

func readAndVerify(path, kind, scope, role string, binding contract.RunBinding, dependencies RehearsalDependencies) (contract.SignedDocument, contract.SignedMetadata, error) {
	var document contract.SignedDocument
	raw, err := readLocalJSON(path)
	if err != nil {
		return document, contract.SignedMetadata{}, err
	}
	document, err = input.DecodeSignedDocument(raw)
	if err != nil {
		return document, contract.SignedMetadata{}, err
	}
	metadata, err := input.VerifyDocument(document, verificationPolicy(kind, scope, role, binding, dependencies))
	return document, metadata, err
}

func verificationPolicy(kind, scope, role string, binding contract.RunBinding, dependencies RehearsalDependencies) input.VerificationPolicy {
	policyBinding := binding
	if kind == "approval" {
		policyBinding.InputDigests = make(map[string]string, len(binding.InputDigests)+1)
		for key, digest := range binding.InputDigests {
			policyBinding.InputDigests[key] = digest
		}
		policyBinding.InputDigests["approval"] = binding.InputDigests["capture_approval"]
	}
	return input.VerificationPolicy{Kind: kind, Scope: scope, Role: role, Binding: policyBinding, Roots: dependencies.TrustRoots,
		Revocations: dependencies.Revocations, Now: dependencies.Clock}
}

func readBinding(path string) (contract.RunBinding, error) {
	var binding contract.RunBinding
	raw, err := readLocalJSON(path)
	if err != nil {
		return binding, err
	}
	if err := contract.DecodeStrict(raw, &binding); err != nil {
		return binding, err
	}
	var wire map[string]any
	if err := contract.DecodeStrict(raw, &wire); err != nil {
		return binding, err
	}
	if err := contract.ValidateSchema("binding", wire); err != nil {
		return binding, err
	}
	if err := contract.ValidateBinding(binding); err != nil {
		return binding, err
	}
	return binding, nil
}

func readLocalJSON(path string) ([]byte, error) {
	if path == "" || !filepath.IsAbs(path) {
		return nil, fmt.Errorf("input path must be absolute")
	}
	parent := filepath.Dir(path)
	parentInfo, err := os.Lstat(parent)
	resolvedParent, resolveErr := filepath.EvalSymlinks(parent)
	if err != nil || resolveErr != nil || resolvedParent != filepath.Clean(parent) || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("input must be a regular non-symlink file")
	}
	root, err := os.OpenRoot(parent)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	pinnedParent, err := root.Stat(".")
	if err != nil || !os.SameFile(parentInfo, pinnedParent) {
		return nil, fmt.Errorf("input parent identity changed while opening")
	}
	name := filepath.Base(path)
	before, err := root.Lstat(name)
	if err != nil || !before.Mode().IsRegular() || before.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("input must be a regular non-symlink file")
	}
	if before.Size() > 16<<20 {
		return nil, fmt.Errorf("input exceeds 16 MiB limit")
	}
	file, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(before, opened) {
		return nil, fmt.Errorf("input identity changed while opening")
	}
	data, err := io.ReadAll(io.LimitReader(file, (16<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 16<<20 {
		return nil, fmt.Errorf("input exceeds 16 MiB limit")
	}
	after, err := file.Stat()
	if err != nil || !os.SameFile(opened, after) || after.Size() != opened.Size() || after.ModTime() != opened.ModTime() || len(data) != int(after.Size()) {
		return nil, fmt.Errorf("input changed while reading")
	}
	return data, nil
}
