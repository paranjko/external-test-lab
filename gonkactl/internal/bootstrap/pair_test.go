package bootstrap

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestPairProcessInterruption(t *testing.T) {
	if directory := os.Getenv("GONKACTL_PAIR_CRASH_FIXTURE"); directory != "" {
		store, err := openPairStore(directory, "gonka-devnet-community")
		if err != nil {
			t.Fatal(err)
		}
		raw, env := testPair(t)
		store.afterWrite = func(index int) error {
			if index == 0 {
				os.Exit(73)
			}
			return nil
		}
		if _, err := store.Commit(append(raw, '\n'), env); err != nil {
			t.Fatal(err)
		}
		t.Fatal("crash injection did not run")
	}
	for _, existing := range []bool{false, true} {
		t.Run(map[bool]string{false: "create", true: "replace"}[existing], func(t *testing.T) {
			directory := t.TempDir()
			chain := "gonka-devnet-community"
			store, err := openPairStore(directory, chain)
			if err != nil {
				t.Fatal(err)
			}
			if existing {
				raw, env := testPair(t)
				if _, err := store.Commit(raw, env); err != nil {
					t.Fatal(err)
				}
				// Different ENV bytes make the interrupted replacement observably partial.
				if err := os.WriteFile(store.paths()[1], []byte("previous ENV"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var before [2]fileState
			for i, path := range store.paths() {
				before[i], err = snapshot(path)
				if err != nil {
					t.Fatal(err)
				}
			}
			store.Close()
			command := exec.Command(os.Args[0], "-test.run=^TestPairProcessInterruption$")
			command.Env = append(os.Environ(), "GONKACTL_PAIR_CRASH_FIXTURE="+directory)
			output, err := command.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 73 {
				t.Fatalf("child did not crash at intended boundary: %v %s", err, output)
			}
			if _, _, err := readPair(directory, chain); err == nil {
				t.Fatal("reader accepted interrupted pair")
			}
			recovered, err := openPairStore(directory, chain)
			if err != nil {
				t.Fatal(err)
			}
			defer recovered.Close()
			for i, path := range recovered.paths() {
				got, err := snapshot(path)
				if err != nil || !sameState(got, before[i]) {
					t.Fatalf("crash recovery lost previous state: %v", err)
				}
			}
			if err := pendingTransaction(directory, chain); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPairReaderExcludesWriterWithoutMutating(t *testing.T) {
	directory := t.TempDir()
	chain := "gonka-devnet-community"
	raw, env := testPair(t)
	for suffix, data := range map[string][]byte{"json": raw, "env": env} {
		if err := os.WriteFile(filepath.Join(directory, chain+"."+suffix), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := readPair(directory, chain); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 2 {
		t.Fatal("read-only validation created state")
	}
	store, err := openPairStore(directory, chain)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := readPair(directory, chain); err == nil {
		t.Fatal("reader raced active writer")
	}
	store.Close()
	if _, _, err := readPair(directory, chain); err != nil {
		t.Fatal(err)
	}
}

func testPair(t *testing.T) ([]byte, []byte) {
	t.Helper()
	raw := fixture(t)
	doc, err := Parse(raw, nil)
	if err != nil {
		t.Fatal(err)
	}
	return raw, doc.ENV()
}

func TestPairCreationNoopRollbackAndOutsideChanges(t *testing.T) {
	directory := t.TempDir()
	chain := "gonka-devnet-community"
	store, err := openPairStore(directory, chain)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if other, err := openPairStore(directory, chain); err == nil {
		other.Close()
		t.Fatal("concurrent writer accepted")
	}
	raw, env := testPair(t)
	if changed, err := store.Commit(raw, env); err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	if changed, err := store.Commit(raw, env); err != nil || changed {
		t.Fatalf("noop changed=%v err=%v", changed, err)
	}
	before := store.before
	store.afterWrite = func(index int) error {
		if index == 0 {
			return errors.New("simulated second-write failure")
		}
		return nil
	}
	updated := append(append([]byte(nil), raw...), '\n')
	if _, err := store.Commit(updated, env); err == nil {
		t.Fatal("write failure hidden")
	}
	for index, path := range store.paths() {
		state, err := snapshot(path)
		if err != nil || !sameState(state, before[index]) {
			t.Fatalf("rollback mismatch: %v", err)
		}
	}
	if err := pendingTransaction(directory, chain); err != nil {
		t.Fatal(err)
	}
	store.afterWrite = nil
	if err := os.WriteFile(store.paths()[1], []byte("external change"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Commit(updated, env); err == nil {
		t.Fatal("external edit overwritten")
	}
}

func TestInterruptedPairRecovery(t *testing.T) {
	for _, complete := range []bool{false, true} {
		t.Run(map[bool]string{false: "partial", true: "complete"}[complete], func(t *testing.T) {
			directory := t.TempDir()
			chain := "gonka-devnet-community"
			store, err := openPairStore(directory, chain)
			if err != nil {
				t.Fatal(err)
			}
			raw, env := testPair(t)
			if _, err := store.Commit(raw, env); err != nil {
				t.Fatal(err)
			}
			after := store.before
			after[0].Data = append(append([]byte(nil), raw...), '\n')
			journal := pairJournal{Version: 1, Chain: chain, Before: store.before, After: after}
			encoded, _ := json.Marshal(journal)
			if err := os.WriteFile(transactionPath(directory, chain), encoded, 0600); err != nil {
				t.Fatal(err)
			}
			if err := store.atomicWrite(store.paths()[0], after[0]); err != nil {
				t.Fatal(err)
			}
			// Make both halves differ so an interruption is observably partial.
			if !complete {
				journal.Before[1].Data = []byte("previous stale ENV")
				if err := os.WriteFile(store.paths()[1], journal.Before[1].Data, 0644); err != nil {
					t.Fatal(err)
				}
				encoded, _ = json.Marshal(journal)
				if err := os.WriteFile(transactionPath(directory, chain), encoded, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, _, err := readPair(directory, chain); err == nil {
				t.Fatal("reader accepted pending transaction")
			}
			store.Close()
			reopened, err := openPairStore(directory, chain)
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			want := journal.Before
			if complete {
				want = journal.After
			}
			for index, path := range reopened.paths() {
				got, err := snapshot(path)
				if err != nil || !sameState(got, want[index]) {
					t.Fatalf("recovery mismatch: %+v %v", got, err)
				}
			}
		})
	}
}

func TestPairRecoveryRefusesForeignEditAndSymlink(t *testing.T) {
	directory := t.TempDir()
	chain := "gonka-devnet-community"
	store, err := openPairStore(directory, chain)
	if err != nil {
		t.Fatal(err)
	}
	raw, env := testPair(t)
	if _, err := store.Commit(raw, env); err != nil {
		t.Fatal(err)
	}
	journal := pairJournal{Version: 1, Chain: chain, Before: store.before, After: store.before}
	encoded, _ := json.Marshal(journal)
	if err := os.WriteFile(transactionPath(directory, chain), encoded, 0600); err != nil {
		t.Fatal(err)
	}
	foreign := []byte("foreign bytes")
	if err := os.WriteFile(store.paths()[0], foreign, 0644); err != nil {
		t.Fatal(err)
	}
	store.Close()
	if next, err := openPairStore(directory, chain); err == nil {
		next.Close()
		t.Fatal("foreign edit recovered over")
	}
	got, _ := os.ReadFile(filepath.Join(directory, chain+".json"))
	if !bytes.Equal(got, foreign) {
		t.Fatal("foreign bytes lost")
	}
	other := t.TempDir()
	target := filepath.Join(other, "unrelated")
	if err := os.WriteFile(target, foreign, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(other, chain+".json")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if next, err := openPairStore(other, chain); err == nil {
		next.Close()
		t.Fatal("symlink output accepted")
	}
	got, _ = os.ReadFile(target)
	if !bytes.Equal(got, foreign) {
		t.Fatal("symlink target modified")
	}
}
