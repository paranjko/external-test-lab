// Package contracts is the frozen v1 boundary between CLI/domain handlers and
// local adapters. Copy this file byte-for-byte to gonkactl/internal/contracts/
// in T001. Wire DTOs are validated against the frozen runtime.schema.json.
package contracts

import (
	"context"
	"encoding/json"
	"io"
	"time"
)

const ServiceABI = 1

// Execute returns the complete CLI result envelope, never an operation_receipt.
// Known outcomes (including failed/blocked/cancelled) return a valid Result and
// nil error. A non-nil error means no returned Result may be trusted; the CLI
// emits the fixed internal_error fallback in output-contract.md.
// Execute never writes stdout and never calls os.Exit.
type Handler interface {
	Execute(context.Context, json.RawMessage) (Result, error)
}

// StreamingHandler is used only by the log renderer; stream output is not a
// Result and never gets a trailing result JSON. CLI supplies the writer.
type StreamingHandler interface {
	Stream(context.Context, json.RawMessage, io.Writer) error
}

// Result is exactly runtime.schema.json#/$defs/result. All fields serialize;
// no omitempty is permitted. CLI validates before one JSON encoding + LF.
type Result struct {
	SchemaVersion int             `json:"schema_version"`
	Command       string          `json:"command"`
	RunID         *string         `json:"run_id"`
	Status        string          `json:"status"`
	Phase         string          `json:"phase"`
	Code          string          `json:"code"`
	Mutation      string          `json:"mutation"`
	SignerState   string          `json:"signer_state"`
	Data          ResultData      `json:"result"`
	Resume        json.RawMessage `json:"resume"`
	Error         *ResultError    `json:"error"`
	ExitCode      int             `json:"exit_code"`
}

type ResultData struct {
	Receipts                 []json.RawMessage `json:"receipts"`
	Outputs                  []json.RawMessage `json:"outputs"`
	PendingActions           []json.RawMessage `json:"pending_actions"`
	JoinComplete             *bool             `json:"join_complete"`
	LifecycleVerified        *bool             `json:"lifecycle_verified"`
	GenesisCreated           *bool             `json:"genesis_created"`
	NetworkBootstrapComplete *bool             `json:"network_bootstrap_complete"`
	VerificationLevel        *string           `json:"verification_level"`
	AccountDerivation        *string           `json:"account_derivation"`
	FullyVerified            *bool             `json:"fully_verified"`
	FencingAssurance         *string           `json:"fencing_assurance"`
	RequiresQualification    bool              `json:"requires_qualification"`
	Healthy                  *bool             `json:"healthy"`
	Matrix                   json.RawMessage   `json:"matrix"`
	Profile                  json.RawMessage   `json:"profile"`
	Version                  *VersionInfo      `json:"version"`
	Help                     *HelpInfo         `json:"help"`
}

type ResultError struct {
	Code      string  `json:"code"`
	Message   string  `json:"message"`
	Retryable bool    `json:"retryable"`
	Cause     *string `json:"cause"`
}

type VersionInfo struct {
	Version      string `json:"version"`
	Commit       string `json:"commit"`
	GoVersion    string `json:"go_version"`
	AssetsSHA256 string `json:"assets_sha256"`
	GuardABI     int    `json:"guard_abi"`
	ServiceABI   int    `json:"service_abi"`
}

type HelpInfo struct {
	Command string `json:"command"`
	Text    string `json:"text"`
}

// EmptyResultData fixes absent-vs-null behavior for every command. Domain
// handlers set only applicable typed fields and append validated receipts.
func EmptyResultData() ResultData {
	return ResultData{
		Receipts:       []json.RawMessage{},
		Outputs:        []json.RawMessage{},
		PendingActions: []json.RawMessage{},
	}
}

type Dependencies struct {
	Root      string // absolute local instance home, never a remote target
	Store     Store
	Runner    Runner
	Runtime   Runtime
	Artifacts Artifact
	Snapshots Snapshot
	Clock     Clock
	Events    EventSink
	Validator Validator
}

type Validator interface {
	Validate(schemaRef string, value json.RawMessage) error
}

// Store keys are relative paths from a finite command-owned allowlist. CAS is
// fsync(temp), rename, fsync(parent); nil expectedSHA256 means create-only.
// All writes are schema-validated before entering Store.
type Store interface {
	Read(ctx context.Context, key string) (Document, error)
	CAS(ctx context.Context, key string, expectedSHA256 *string, next Document) error
	Lock(ctx context.Context, resource string) (Lock, error)
}

type Document struct {
	SchemaRef string
	Bytes     json.RawMessage
	SHA256    string
}

type Lock interface{ Close() error }

// Runner accepts argv, never shell source. Env is an explicit reviewed
// allowlist. Stdin may carry a secret and is never copied into evidence.
type Runner interface {
	Run(context.Context, ProcessSpec) (ProcessResult, error)
}

type ProcessSpec struct {
	Executable       string
	Args             []string
	Directory        string
	Env              []string
	Stdin            io.Reader
	Timeout          time.Duration
	OutputLimitBytes int64
}

type ProcessResult struct {
	ExitCode  int
	Stdout    []byte // bounded; domain must sanitize before emitting evidence
	Stderr    []byte // bounded; not automatically logged
	Truncated bool
}

// Runtime only accepts the frozen deployment generation's absolute directory.
// It explicitly rejects Docker contexts/hosts other than the local Unix socket.
type Runtime interface {
	Inspect(ctx context.Context, generationDir string) (RuntimeState, error)
	Apply(ctx context.Context, generationDir string) error
	Start(ctx context.Context, generationDir string, services []string) error
	Stop(ctx context.Context, generationDir string, services []string) error
}

type RuntimeState struct {
	GenerationID string
	ServiceABI   int
	Services     []ServiceState
}

type ServiceState struct {
	Name          string
	ContainerID   string
	ImageDigest   string
	Running       bool
	Health        string // exactly absent|starting|healthy|unhealthy|unknown
	RestartPolicy string
	Mounts        []Mount
}

type Mount struct {
	Source, Destination string
	ReadOnly            bool
}

type Artifact interface {
	Fetch(context.Context, ArtifactRequest) (ArtifactFile, error)
}

type ArtifactRequest struct {
	URL       string
	SHA256    string
	SizeBytes int64
	CacheRoot string
}

type ArtifactFile struct {
	Path, SHA256 string
	SizeBytes    int64
}

// Copy opens source no-follow and creates a bounded private snapshot. Ownership
// is the caller's effective UID (non-root offline verifier; root import).
// The returned immutable snapshot is the ONLY subsequent verification input.
type Snapshot interface {
	Copy(context.Context, SnapshotRequest) (SnapshotFile, error)
}

type SnapshotRequest struct {
	SourcePath    string
	PrivateParent string
	MaxBytes      int64
	RequireRoot   bool
}

type SnapshotFile interface {
	Path() string
	SHA256() string
	SizeBytes() int64
	Open() (io.ReadCloser, error)
	Close() error // closes readers, unlinks snapshot and private operation dir
}

type Clock interface {
	Now() time.Time
	Wait(context.Context, time.Duration) error
}

// Emit accepts a runtime.schema.json#/$defs/event value after allowlist
// sanitization. It writes audit/stderr sinks only, never stdout.
type EventSink interface {
	Emit(context.Context, json.RawMessage) error
}

type Error struct {
	Code        string
	ExitCode    int
	Phase       string
	Retryable   bool
	SafeMessage string
}

func (e *Error) Error() string { return e.SafeMessage }
