package capture

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const (
	minimumCPUs        = 8
	minimumRAM         = 16 << 30
	minimumDiskReserve = 10 << 30
)

type EvidenceReference struct {
	Available bool   `json:"available"`
	Reference string `json:"reference,omitempty"`
	SHA256    string `json:"sha256,omitempty"`
}
type LayoutEvidence struct {
	EvidenceReference
	Backend    string `json:"backend,omitempty"`
	Layout     string `json:"layout,omitempty"`
	Version    string `json:"version,omitempty"`
	SnapshotID string `json:"snapshot_id,omitempty"`
}
type WitnessInput struct {
	EvidenceReference
	Identity      string `json:"identity,omitempty"`
	BlockID       string `json:"block_id,omitempty"`
	BlockHeight   int64  `json:"block_height,omitempty"`
	AppHash       string `json:"app_hash,omitempty"`
	AppHashHeight int64  `json:"app_hash_height,omitempty"`
}
type OfflineReaderInput struct {
	EvidenceReference
	ConsensusHeight *int64 `json:"consensus_height,omitempty"`
}
type PreflightEvidence struct {
	Freeze          EvidenceReference  `json:"freeze"`
	Layout          LayoutEvidence     `json:"layout"`
	Inventory       EvidenceReference  `json:"inventory"`
	CaptureApproval EvidenceReference  `json:"capture_approval"`
	Witnesses       []WitnessInput     `json:"witnesses"`
	OfflineReader   OfflineReaderInput `json:"offline_reader"`
}
type Capacity struct {
	CPUs                    int   `json:"cpus"`
	RAMBytes                int64 `json:"ram_bytes"`
	WorkspaceAvailableBytes int64 `json:"workspace_available_bytes"`
	CaptureAvailableBytes   int64 `json:"capture_available_bytes"`
}
type Diagnostic struct {
	Code        string `json:"code"`
	Requirement string `json:"requirement"`
	Message     string `json:"message"`
}

// PreflightReport describes whether required inputs and declared capacity are
// present. It never verifies signatures, quorum, snapshot consistency, or
// operator authorization and therefore can never authorize capture.
type PreflightReport struct {
	Status                 string       `json:"status"`
	InputsComplete         bool         `json:"inputs_complete"`
	CaptureAuthorized      bool         `json:"capture_authorized"`
	Qualification          string       `json:"qualification"`
	ExportBytes            int64        `json:"export_bytes"`
	RequiredWorkspaceBytes int64        `json:"required_workspace_bytes"`
	RequiredCaptureBytes   int64        `json:"required_capture_bytes"`
	Diagnostics            []Diagnostic `json:"diagnostics"`
	Unverified             []Diagnostic `json:"unverified"`
}

// OfflinePreflight is a pure local check. Capacity targets follow the plan's
// rehearsal sizing rule (5x export plus 10 GiB), not measured incident needs.
func OfflinePreflight(binding contract.RunBinding, manifest contract.SourceManifest, sourcePayload []byte, policy Policy, evidence PreflightEvidence, capacity Capacity) PreflightReport {
	r := PreflightReport{Status: "BLOCKED", Qualification: "not_evaluated", CaptureAuthorized: false}
	add := func(code, requirement, message string) {
		r.Diagnostics = append(r.Diagnostics, Diagnostic{code, requirement, message})
	}
	if err := validateSourcePayloadBinding(binding, manifest, sourcePayload); err != nil {
		add("source_manifest_unavailable", "exact signed source manifest", err.Error())
	}
	if err := validatePolicy(manifest, policy); err != nil {
		add("catalog_inventory_unavailable", "verified catalog exact file/component allowlist", err.Error())
	}
	for _, x := range []struct {
		name string
		ref  EvidenceReference
	}{{"operator freeze/checkpoint receipt", evidence.Freeze}, {"source inventory receipt", evidence.Inventory}, {"scoped capture approval", evidence.CaptureApproval}} {
		checkReference(x.name, x.ref, add)
	}
	if !evidence.Layout.Available {
		add("layout_proof_missing", "exact source layout/backend/version", "layout proof is unavailable")
	} else {
		checkReference("layout/backend/version proof", evidence.Layout.EvidenceReference, add)
		if evidence.Layout.Backend != manifest.Backend || evidence.Layout.Layout != manifest.Layout || evidence.Layout.Version != manifest.BackendVersion || evidence.Layout.SnapshotID != manifest.SnapshotID {
			add("layout_proof_mismatch", "exact source layout/backend/version/snapshot", "layout proof does not match frozen manifest")
		}
	}
	if len(evidence.Witnesses) < 2 {
		add("witnesses_missing", "two independent source witnesses", "fewer than two witness inputs are available")
	}
	seen := map[string]bool{}
	for i, w := range evidence.Witnesses {
		label := fmt.Sprintf("witness %d", i+1)
		checkReference(label, w.EvidenceReference, add)
		if w.Identity == "" {
			add("witness_identity_missing", label, "identity is missing")
		} else if seen[w.Identity] {
			add("witness_identity_duplicate", label, "witness identity is not independent")
		}
		seen[w.Identity] = true
		if w.BlockID != binding.BlockID || w.BlockHeight != binding.Heights.Blockstore || w.AppHash != binding.AppHash || w.AppHashHeight != binding.Heights.App {
			add("witness_binding_mismatch", label, "witness heights or hashes differ from run binding")
		}
	}
	if !evidence.OfflineReader.Available {
		add("offline_reader_missing", "offline consensus-height reader evidence", "offline reader evidence is unavailable")
	}
	checkReference("offline consensus-height reader", evidence.OfflineReader.EvidenceReference, add)
	if evidence.OfflineReader.ConsensusHeight == nil || binding.Heights.Consensus == nil {
		add("consensus_height_unknown", "consensus-state height", "consensus-state height is unknown")
	} else if *evidence.OfflineReader.ConsensusHeight != *binding.Heights.Consensus {
		add("consensus_height_mismatch", "consensus-state height", "offline reader height differs from run binding")
	}
	if manifest.Heights.Consensus == nil || binding.Heights.Consensus == nil {
		add("manifest_consensus_height_unknown", "manifest consensus-state height", "frozen source manifest does not bind consensus-state height")
	} else if !sameHeights(manifest.Heights, binding.Heights) {
		add("manifest_height_mismatch", "three-height source binding", "manifest heights differ from run binding")
	}
	if evidence.CaptureApproval.Available {
		r.Unverified = append(r.Unverified, Diagnostic{"approval_not_verified", "scoped capture approval", "preflight checks only reference availability; signature, scope, expiry and revocation are not verified"})
	}
	if len(sourcePayload) > 0 {
		r.Unverified = append(r.Unverified, Diagnostic{"source_manifest_signature_not_verified", "signed source manifest", "preflight verifies payload binding only; pinned signature, expiry and revocation checks are not performed"})
	}
	if evidence.Layout.Available {
		r.Unverified = append(r.Unverified, Diagnostic{"layout_evidence_not_verified", "source layout/backend/version", "preflight compares declared fields but does not validate the referenced evidence signature or provenance"})
	}
	if evidence.Inventory.Available {
		r.Unverified = append(r.Unverified, Diagnostic{"inventory_receipt_not_verified", "exact source inventory", "preflight validates manifest against policy but does not verify the referenced inventory receipt"})
	}
	if len(evidence.Witnesses) > 0 {
		r.Unverified = append(r.Unverified, Diagnostic{"witness_quorum_not_verified", "independent source witnesses", "preflight does not verify witness signatures, validator-set pagination, voting power or quorum"})
	}
	if evidence.Freeze.Available {
		r.Unverified = append(r.Unverified, Diagnostic{"snapshot_consistency_not_verified", "frozen export consistency", "a freeze reference does not prove coordinated quiesce or backend-atomic snapshot consistency"})
	}
	if evidence.OfflineReader.Available {
		r.Unverified = append(r.Unverified, Diagnostic{"offline_reader_not_verified", "offline consensus-state height", "preflight does not inspect a database or validate an offline reader receipt"})
	}
	if n, err := inventoryBytes(manifest.Files); err != nil {
		add("inventory_size_invalid", "exact frozen inventory byte count", err.Error())
	} else {
		r.ExportBytes = n
		r.RequiredCaptureBytes = saturatingAdd(n, policy.ReserveBytes)
		r.RequiredWorkspaceBytes = saturatingAdd(saturatingMultiply(n, 5), minimumDiskReserve)
	}
	if capacity.CPUs < minimumCPUs {
		add("cpu_capacity_insufficient", "rehearsal runner CPU", fmt.Sprintf("need at least %d CPUs; reported %d", minimumCPUs, capacity.CPUs))
	}
	if capacity.RAMBytes < minimumRAM {
		add("memory_capacity_insufficient", "rehearsal runner memory", fmt.Sprintf("need at least %d bytes; reported %d", minimumRAM, capacity.RAMBytes))
	}
	if capacity.WorkspaceAvailableBytes < r.RequiredWorkspaceBytes {
		add("workspace_capacity_insufficient", "rehearsal workspace disk", fmt.Sprintf("plan sizing requires %d bytes (5x export plus 10 GiB); reported available %d", r.RequiredWorkspaceBytes, capacity.WorkspaceAvailableBytes))
	}
	if capacity.CaptureAvailableBytes < r.RequiredCaptureBytes {
		add("capture_capacity_insufficient", "frozen export destination disk", fmt.Sprintf("need export bytes plus reserve: %d; reported available %d", r.RequiredCaptureBytes, capacity.CaptureAvailableBytes))
	}
	if capacity.WorkspaceAvailableBytes <= 0 {
		add("workspace_capacity_unknown", "rehearsal workspace disk", "available capacity is missing or unavailable")
	}
	if capacity.CaptureAvailableBytes <= 0 {
		add("capture_capacity_unknown", "frozen export destination disk", "available capacity is missing or unavailable")
	}
	if len(r.Diagnostics) == 0 {
		r.Status = "INPUTS_PRESENT_UNVERIFIED"
		r.InputsComplete = true
	}
	return r
}

func checkReference(name string, ref EvidenceReference, add func(string, string, string)) {
	if !ref.Available {
		add("evidence_unavailable", name, "required evidence reference is unavailable")
		return
	}
	if ref.Reference == "" {
		add("evidence_reference_missing", name, "available evidence has no stable reference")
	}
	if !contract.IsDigest(ref.SHA256) {
		add("evidence_digest_missing", name, "available evidence lacks a valid SHA-256 digest")
	}
}
func validateSourcePayloadBinding(b contract.RunBinding, m contract.SourceManifest, payload []byte) error {
	if len(payload) == 0 {
		return errors.New("exact source manifest payload is unavailable")
	}
	if err := contract.ValidateBinding(b); err != nil {
		return fmt.Errorf("run binding invalid: %w", err)
	}
	digest, ok := b.InputDigests["source_manifest"]
	if !ok || digest != contract.PayloadDigest(payload) {
		return errors.New("source manifest payload digest is absent or differs from run binding")
	}
	var decoded contract.SourceManifest
	if err := contract.DecodeStrict(payload, &decoded); err != nil {
		return fmt.Errorf("source manifest payload invalid: %w", err)
	}
	want, _ := json.Marshal(m)
	got, _ := json.Marshal(decoded)
	if !bytes.Equal(want, got) {
		return errors.New("typed manifest differs from exact source payload")
	}
	if m.SchemaVersion != contract.Version || m.Kind != "source_manifest" || m.Scope != "capture" || m.RunID != b.RunID || m.ChainID != b.ChainID || m.GenesisSHA256 != b.GenesisSHA256 {
		return errors.New("source manifest identity differs from run binding")
	}
	bindingDigest, err := contract.InputBindingDigest(b)
	if err != nil || m.BindingDigest != bindingDigest {
		return errors.New("source manifest input-binding digest differs from run binding")
	}
	if !sameHeights(m.Heights, b.Heights) {
		return errors.New("source manifest heights differ from run binding")
	}
	return nil
}
func inventoryBytes(files []contract.ExportFile) (int64, error) {
	if len(files) == 0 {
		return 0, errors.New("frozen inventory is absent")
	}
	var total int64
	for _, f := range files {
		if f.Size < 0 || f.Size > math.MaxInt64-total {
			return 0, errors.New("inventory size overflows int64")
		}
		total += f.Size
	}
	return total, nil
}
func saturatingMultiply(n, m int64) int64 {
	if n < 0 || m < 0 || n != 0 && m > math.MaxInt64/n {
		return math.MaxInt64
	}
	return n * m
}
func saturatingAdd(a, b int64) int64 {
	if a < 0 || b < 0 || a > math.MaxInt64-b {
		return math.MaxInt64
	}
	return a + b
}
