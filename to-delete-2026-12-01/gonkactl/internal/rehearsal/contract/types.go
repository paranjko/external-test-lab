// Package contract defines the isolated rehearsal protocol, not live recovery.
package contract

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"
)

const Version = "rehearsal/v1"
const Scenario = "epoch-length-live-update"

type Phase string

const (
	Inspect Phase = "inspect"
	Capture Phase = "capture"
	Stage   Phase = "stage"
	Run     Phase = "run"
	Verify  Phase = "verify"
	Report  Phase = "report"
	Cleanup Phase = "cleanup"
)

type State string

const (
	Planned   State = "planned"
	Running   State = "running"
	Succeeded State = "succeeded"
	Failed    State = "failed"
	Blocked   State = "blocked"
	Unknown   State = "unknown"
)

// Terminal states are immutable; reconciliation records new evidence, not rewrites.
func CanTransition(from, to State) bool {
	return from == Planned && (to == Running || to == Blocked) || from == Running && (to == Succeeded || to == Failed || to == Blocked || to == Unknown)
}

type Verdict string

const (
	Pass           Verdict = "PASS"
	Fail           Verdict = "FAIL"
	VerdictBlocked Verdict = "BLOCKED"
	Inconclusive   Verdict = "INCONCLUSIVE"
)

type Heights struct {
	Blockstore    int64  `json:"blockstore"`
	App           int64  `json:"app"`
	Consensus     *int64 `json:"consensus"`
	FirstRepaired int64  `json:"first_repaired"`
}

type RunBinding struct {
	SchemaVersion     string            `json:"schema_version"`
	RunID             string            `json:"run_id"`
	Scenario          string            `json:"scenario"`
	Workspace         string            `json:"workspace"`
	OwnershipMarker   string            `json:"ownership_marker"`
	ChainID           string            `json:"chain_id"`
	GenesisSHA256     string            `json:"genesis_sha256"`
	Heights           Heights           `json:"heights"`
	BlockID           string            `json:"block_id"`
	AppHash           string            `json:"app_hash"`
	AppHashHeight     int64             `json:"app_hash_height"`
	ToolVersion       string            `json:"tool_version"`
	CatalogVersion    string            `json:"catalog_version"`
	InputDigests      map[string]string `json:"input_digests"`
	RuntimeIdentities map[string]string `json:"runtime_identities"`
	Paths             map[string]string `json:"paths"`
}

func Digest(value any) (string, error) {
	b, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:]), nil
}

// InputBindingDigest binds signed inputs to the run context without a hash
// cycle. InputDigests subsequently pin exact signed payload bytes; receipts
// always use Digest of the complete RunBinding, including those input hashes.
func InputBindingDigest(binding RunBinding) (string, error) {
	binding.InputDigests = nil
	return Digest(struct {
		Domain  string     `json:"domain"`
		Binding RunBinding `json:"binding"`
	}{"rehearsal-input-context/v1", binding})
}

func PayloadDigest(payload []byte) string {
	h := sha256.Sum256(payload)
	return hex.EncodeToString(h[:])
}

// Payload is the exact signed JSON; never reserialize it before verification.
type SignedDocument struct {
	Payload      json.RawMessage `json:"payload"`
	SignatureHex string          `json:"signature_hex"`
}

type SignedMetadata struct {
	SchemaVersion string    `json:"schema_version"`
	Kind          string    `json:"kind"`
	Scope         string    `json:"scope"`
	KeyID         string    `json:"key_id"`
	RunID         string    `json:"run_id"`
	BindingDigest string    `json:"binding_digest"`
	ChainID       string    `json:"chain_id"`
	GenesisSHA256 string    `json:"genesis_sha256"`
	IssuedAt      time.Time `json:"issued_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

type ExportFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type SourceManifest struct {
	SignedMetadata
	SnapshotID     string       `json:"snapshot_id"`
	Checkpoint     string       `json:"checkpoint"`
	Backend        string       `json:"backend"`
	Layout         string       `json:"layout"`
	BackendVersion string       `json:"backend_version"`
	Frozen         bool         `json:"frozen"`
	Heights        Heights      `json:"heights"`
	Files          []ExportFile `json:"files"`
	Components     []string     `json:"components"`
}

type Receipt struct {
	SchemaVersion   string            `json:"schema_version"`
	RunID           string            `json:"run_id"`
	BindingDigest   string            `json:"binding_digest"`
	Phase           Phase             `json:"phase"`
	Operation       string            `json:"operation"`
	State           State             `json:"state"`
	Sequence        uint64            `json:"sequence"`
	Predecessor     string            `json:"predecessor"`
	EvidenceDigests map[string]string `json:"evidence_digests"`
	ExitCode        *int              `json:"exit_code"`
	Reason          string            `json:"reason"`
}

type Outcome struct {
	SchemaVersion string    `json:"schema_version"`
	Scenario      string    `json:"scenario"`
	RunID         string    `json:"run_id,omitempty"`
	Phase         Phase     `json:"phase"`
	Mode          string    `json:"mode"`
	Status        string    `json:"status"`
	Code          string    `json:"code"`
	Mutation      string    `json:"mutation"`
	Qualification string    `json:"qualification"`
	Verdict       Verdict   `json:"verdict,omitempty"`
	Receipts      []Receipt `json:"receipts"`
	ExitCode      int       `json:"exit_code"`
}

// Complete snapshots include empty stores. Missing stores are not empty stores.
type Entry struct {
	Key   []byte `json:"key"`
	Value []byte `json:"value"`
}
type LogicalStore struct {
	Name    string  `json:"name"`
	Entries []Entry `json:"entries"`
}
type Snapshot struct {
	Stores []LogicalStore `json:"stores"`
}
type Value struct {
	Present bool   `json:"present"`
	Bytes   []byte `json:"bytes"`
}
type Change struct {
	Store  string `json:"store"`
	Key    []byte `json:"key"`
	Before Value  `json:"before"`
	After  Value  `json:"after"`
}
type Domain string

const (
	Topology  Domain = "topology"
	Migration Domain = "migration"
	Block     Domain = "block"
)

type DomainEvidence struct {
	Domain    Domain   `json:"domain"`
	Before    Snapshot `json:"before"`
	After     Snapshot `json:"after"`
	Allowlist []Change `json:"allowlist"`
}

// Adapters receive a frozen binding, never arbitrary shell commands or live handlers.
type CaptureAdapter interface {
	Capture(context.Context, RunBinding, SourceManifest) (Receipt, error)
}
type RuntimeAdapter interface {
	Stage(context.Context, RunBinding) (Receipt, error)
	Run(context.Context, RunBinding) (Receipt, error)
	Inspect(context.Context, RunBinding) ([]Receipt, error)
}
type CleanupAdapter interface {
	ValidateOwnership(context.Context, RunBinding) error
	Cleanup(context.Context, RunBinding) (Receipt, error)
}
