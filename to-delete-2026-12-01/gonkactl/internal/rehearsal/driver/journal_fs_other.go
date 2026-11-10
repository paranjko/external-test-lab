//go:build !linux

package driver

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
)

// FSJournal is unavailable on platforms without the Linux locking and
// directory durability implementation.
type FSJournal struct{}

func OpenFSJournal(contract.RunBinding) (*FSJournal, error) { return nil, ErrJournal }
func (*FSJournal) Close() error                             { return nil }
func (*FSJournal) Read(context.Context, string) (Ledger, error) {
	return Ledger{}, ErrJournal
}
func (*FSJournal) Begin(context.Context, string, Step, json.RawMessage) error { return ErrJournal }
func (*FSJournal) Complete(context.Context, string, Step, json.RawMessage) error {
	return ErrJournal
}
func (*FSJournal) Record(context.Context, string, Step, json.RawMessage) error { return ErrJournal }
func (*FSJournal) Unknown(context.Context, string, Step, string) error         { return ErrJournal }
func (*FSJournal) AuthorizeAdoption(context.Context, isolation.PinnedResource) error {
	return errors.Join(ErrJournal, isolation.ErrAdoptionDenied)
}
