package session

import (
	"context"
	"errors"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

// SnapshotReader is a trusted local inspection dependency. Implementations
// receive only the immutable run binding and must read the copied source path
// bound in it; they cannot provide a verdict or a receipt.
type SnapshotReader interface {
	ReadSnapshot(context.Context, contract.RunBinding) (contract.Snapshot, error)
}

// ManifestSnapshotReader requires the source inventory already authenticated
// by Capture. A process-backed reader must verify its disposable copy against
// this inventory before opening any copied database.
type ManifestSnapshotReader interface {
	ReadManifestSnapshot(context.Context, contract.RunBinding, contract.SourceManifest) (contract.Snapshot, error)
}

var (
	ErrCaptureJournalRequired     = errors.New("matching untouched planned run journal is required before capture")
	ErrCaptureVerifierUnavailable = errors.New("capture proof verifier is unavailable")
)

// CaptureRequest carries the exact signed inputs and proof bytes for one
// explicitly requested local capture. ProofVerifier is intentionally opaque
// here so the CLI remains buildable on platforms where capture is unavailable.
type CaptureRequest struct {
	Binding          contract.RunBinding
	CatalogDocument  contract.SignedDocument
	CatalogPolicy    catalog.Policy
	ArtifactDocument contract.SignedDocument
	ArtifactPolicy   catalog.Policy
	SourceDocument   contract.SignedDocument
	SourcePolicy     input.VerificationPolicy
	Approval         contract.SignedDocument
	ApprovalPolicy   input.VerificationPolicy
	Manifest         contract.SourceManifest
	FreezePayload    []byte
	LayoutPayload    []byte
	InventoryPayload []byte
	WitnessPayloads  [][]byte
	OfflineReader    []byte
	Verifier         any
	SnapshotReader   SnapshotReader
	MaxBytes         int64
	ReserveBytes     int64
}
