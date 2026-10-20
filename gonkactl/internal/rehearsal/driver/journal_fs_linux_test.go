//go:build linux

package driver

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
)

func TestFSJournalPersistsExactOrderedRecordsAndAuthorizesCreateAdoption(t *testing.T) {
	_, _, _, _, plan, binding := driverFixture(t, false)
	ctx := context.Background()
	digest := bindingDigest(binding)
	journal, err := OpenFSJournal(binding)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := journal.Read(ctx, digest); err != nil {
		t.Fatal(err)
	}
	if _, err := journal.Read(ctx, strings.Repeat("0", 64)); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("different immutable binding digest accepted: %v", err)
	}
	if err := journal.Record(ctx, digest, ControlCreate, json.RawMessage(`{}`)); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("create record without durable intent accepted: %v", err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); err != nil {
		t.Fatal(err)
	}
	pin := fsJournalTestPin(binding, digest, plan.Control, strings.Repeat("e", 64))
	raw, err := json.Marshal(pin)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Complete(ctx, digest, ControlCreate, raw); err != nil {
		t.Fatal(err)
	}
	if err := journal.AuthorizeAdoption(ctx, pin); err != nil {
		t.Fatalf("durable exact create completion did not authorize adoption: %v", err)
	}
	changed := pin
	changed.ID = strings.Repeat("f", 64)
	if err := journal.AuthorizeAdoption(ctx, changed); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("different pin authorized for adoption: %v", err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	journal, err = OpenFSJournal(binding)
	if err != nil {
		t.Fatalf("reopen durable journal: %v", err)
	}
	defer journal.Close()
	ledger, err := journal.Read(ctx, digest)
	if err != nil {
		t.Fatal(err)
	}
	if len(ledger.Completed) != 1 || ledger.Completed[0].Step != ControlCreate || string(ledger.Completed[0].Evidence) != string(raw) {
		t.Fatalf("reopened ledger lost exact completion bytes: %+v", ledger)
	}
	if err := journal.AuthorizeAdoption(ctx, pin); err != nil {
		t.Fatalf("reopened exact completion no longer authorizes adoption: %v", err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("completed create replay accepted: %v", err)
	}
	if err := journal.Begin(ctx, digest, ControlStart, raw); err != nil {
		t.Fatalf("next ordered intent rejected: %v", err)
	}
}

func TestFSJournalRecoveredPendingAndUnknownCannotResumeOrAdopt(t *testing.T) {
	_, _, _, _, plan, binding := driverFixture(t, false)
	ctx := context.Background()
	digest := bindingDigest(binding)
	journal, err := OpenFSJournal(binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	journal, err = OpenFSJournal(binding)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := journal.Read(ctx, digest)
	if err != nil || ledger.Pending == nil || *ledger.Pending != ControlCreate {
		t.Fatalf("pending intent not recovered: ledger=%+v err=%v", ledger, err)
	}
	pin := fsJournalTestPin(binding, digest, plan.Control, strings.Repeat("e", 64))
	if err := journal.AuthorizeAdoption(ctx, pin); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("pending create authorized adoption: %v", err)
	}
	raw, _ := json.Marshal(pin)
	if err := journal.Complete(ctx, digest, ControlCreate, raw); !errors.Is(err, ErrUnknown) {
		t.Fatalf("recovered pending mutation was resumed: %v", err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); !errors.Is(err, ErrUnknown) {
		t.Fatalf("recovered pending mutation was replayed: %v", err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestFSJournalUnknownIsTerminal(t *testing.T) {
	_, _, _, _, _, binding := driverFixture(t, false)
	ctx := context.Background()
	digest := bindingDigest(binding)
	journal, err := OpenFSJournal(binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); err != nil {
		t.Fatal(err)
	}
	if err := journal.Unknown(ctx, digest, ControlCreate, "runtime outcome unavailable"); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	journal, err = OpenFSJournal(binding)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	ledger, err := journal.Read(ctx, digest)
	if err != nil || !ledger.Unknown || ledger.Pending == nil {
		t.Fatalf("unknown state not persisted: ledger=%+v err=%v", ledger, err)
	}
	if err := journal.AuthorizeAdoption(ctx, isolation.PinnedResource{}); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("unknown state authorized adoption: %v", err)
	}
	if err := journal.Begin(ctx, digest, ControlCreate, json.RawMessage(`null`)); !errors.Is(err, ErrUnknown) {
		t.Fatalf("unknown state allowed replay: %v", err)
	}
}

func TestFSJournalRejectsTamperingAndTornTail(t *testing.T) {
	t.Run("modified event", func(t *testing.T) {
		_, _, _, _, _, binding := driverFixture(t, false)
		digest := bindingDigest(binding)
		journal, err := OpenFSJournal(binding)
		if err != nil {
			t.Fatal(err)
		}
		if err := journal.Record(context.Background(), digest, ControlCreate, json.RawMessage(`{}`)); !errors.Is(err, ErrPrecondition) {
			t.Fatalf("invalid create record accepted: %v", err)
		}
		if err := journal.Begin(context.Background(), digest, ControlCreate, json.RawMessage(`null`)); err != nil {
			t.Fatal(err)
		}
		pin := isolation.PinnedResource{ID: strings.Repeat("e", 64), Name: "control-old", RunID: binding.RunID, OwnershipMarker: binding.OwnershipMarker, BindingDigest: digest, ForkKey: "fork-b", Image: testImage, SelectedBinaryRole: isolation.BinaryOriginal, SelectedBinaryPath: binding.Paths["original-binary"], SelectedBinaryDigest: binding.InputDigests["original-binary"]}
		raw, _ := json.Marshal(pin)
		if err := journal.Complete(context.Background(), digest, ControlCreate, raw); err != nil {
			t.Fatal(err)
		}
		if err := journal.Close(); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(binding.Workspace, fsJournalName)
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		contents = []byte(strings.Replace(string(contents), `"id":"`+strings.Repeat("e", 64)+`"`, `"id":"`+strings.Repeat("f", 64)+`"`, 1))
		if err := os.WriteFile(path, contents, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenFSJournal(binding); !errors.Is(err, ErrJournal) {
			t.Fatalf("tampered event accepted: %v", err)
		}
	})

	t.Run("torn tail", func(t *testing.T) {
		_, _, _, _, _, binding := driverFixture(t, false)
		journal, err := OpenFSJournal(binding)
		if err != nil {
			t.Fatal(err)
		}
		if err := journal.Close(); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(binding.Workspace, fsJournalName)
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.WriteString(`{"schema":"partial"}`); err != nil {
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenFSJournal(binding); !errors.Is(err, ErrJournal) {
			t.Fatalf("torn tail accepted: %v", err)
		}
	})
}

func fsJournalTestPin(binding contract.RunBinding, digest string, spec isolation.ContainerSpec, id string) isolation.PinnedResource {
	fork := selectedFork(spec)
	role := spec.SelectedBinaryRole
	return isolation.PinnedResource{
		ID: id, Name: spec.Name, RunID: binding.RunID,
		OwnershipMarker: binding.OwnershipMarker, BindingDigest: digest,
		ForkKey: fork, Image: spec.Image, Argv: append([]string(nil), spec.Argv...),
		Entrypoint: append([]string(nil), spec.Entrypoint...), Environment: spec.Environment,
		DNSAliases: append([]string(nil), spec.DNSAliases...), ForkTarget: spec.ForkTarget,
		SelectedBinaryRole: role, SelectedBinaryPath: binding.Paths[string(role)+"-binary"],
		SelectedBinaryDigest: binding.InputDigests[string(role)+"-binary"],
	}
}
