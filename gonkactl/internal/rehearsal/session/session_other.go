//go:build !linux

// Package session exposes the same CLI API on non-Linux platforms while
// refusing persisted journal access until a platform-safe lock implementation
// is available. This keeps the general CLI build portable and fails closed.
package session

import (
	"context"
	"errors"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

var ErrInvalidSession = errors.New("persisted rehearsal evidence is unavailable on this platform")

type Run struct {
	Binding  contract.RunBinding
	State    contract.State
	Revision string
	Receipts []contract.Receipt
}

func Load(string, string) (Run, error) { return Run{}, ErrInvalidSession }

func Verify(string, string) (evidence.Result, error) {
	return evidence.Result{}, ErrInvalidSession
}

func VerifyFresh(context.Context, string, string, contract.SignedDocument, contract.SignedDocument, contract.SignedDocument, contract.SignedDocument, []input.TrustRoot, input.RevocationSnapshot, func() time.Time) (evidence.Result, error) {
	return evidence.Result{}, ErrInvalidSession
}

func WriteVerification(string, evidence.Result) error { return ErrInvalidSession }

func WriteReport(string, string) (evidence.Result, error) {
	return evidence.Result{}, ErrInvalidSession
}

func WriteReportResult(string, evidence.Result) error { return ErrInvalidSession }

func Capture(context.Context, CaptureRequest) (contract.Receipt, error) {
	return contract.Receipt{}, ErrInvalidSession
}
