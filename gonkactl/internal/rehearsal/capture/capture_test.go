package capture

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestCopyFrozenFixture(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src")
	dst := filepath.Join(base, "dst")
	if err := os.Mkdir(src, 0o700); err != nil {
		t.Fatal(err)
	}
	body := []byte("fixture database bytes")
	if err := os.WriteFile(filepath.Join(src, "data.db"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	m := contract.SourceManifest{Frozen: true, Components: []string{"blockstore"}, Files: []contract.ExportFile{{Path: "data.db", SHA256: hex.EncodeToString(sum[:]), Size: int64(len(body))}}}
	p := Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{"data.db"}, Backend: "fixture", Layout: "single", BackendVersion: "v1", MaxBytes: 1024, ReserveBytes: 1}
	m.Backend, m.Layout, m.BackendVersion = p.Backend, p.Layout, p.BackendVersion
	r, err := Copy(context.Background(), src, dst, m, p)
	if err != nil {
		t.Fatal(err)
	}
	if r.Bytes != int64(len(body)) || len(r.Files) != 1 || r.PayloadSHA256 == "" || r.ManifestSHA256 == "" {
		t.Fatalf("unexpected result: %#v", r)
	}
	got, err := os.ReadFile(filepath.Join(dst, "data.db"))
	if err != nil || string(got) != string(body) {
		t.Fatalf("copied content %q, %v", got, err)
	}
	if st, _ := os.Stat(dst); st.Mode().Perm() != 0o700 {
		t.Fatalf("destination mode %o", st.Mode().Perm())
	}
	if st, _ := os.Stat(filepath.Join(dst, "data.db")); st.Mode().Perm() != 0o600 {
		t.Fatalf("file mode %o", st.Mode().Perm())
	}
	got, err = os.ReadFile(filepath.Join(src, "data.db"))
	if err != nil || string(got) != string(body) {
		t.Fatal("source changed")
	}
}

func TestAdapterBindsPayloadRunPathsAndParentSync(t *testing.T) {
	base := t.TempDir()
	adapter, binding, manifest := testAuthorizedAdapter(t, base, "run1")
	called := false
	adapter.SyncParent = func(string) error { called = true; return nil }
	receipt, err := adapter.Capture(context.Background(), binding, manifest)
	if err != nil || receipt.State != contract.Succeeded || !called {
		t.Fatalf("capture receipt=%#v err=%v synced=%v", receipt, err, called)
	}
	for _, mutate := range []func(*Adapter, *contract.RunBinding, *contract.SourceManifest){func(a *Adapter, _ *contract.RunBinding, _ *contract.SourceManifest) { a.SourcePayload = []byte(`{}`) }, func(_ *Adapter, b *contract.RunBinding, _ *contract.SourceManifest) { b.RunID = "other" }, func(a *Adapter, _ *contract.RunBinding, _ *contract.SourceManifest) {
		a.Destination = filepath.Join(base, "elsewhere")
	}} {
		aa := adapter
		bb := binding
		mm := manifest
		if _, err := mutateCall(mutate, &aa, &bb, &mm); err == nil {
			t.Fatal("expected binding rejection")
		}
	}
	parentFail, bb, mm := testAuthorizedAdapter(t, base, "run2")
	parentFail.SyncParent = func(string) error { return errors.New("injected fsync failure") }
	if rec, err := parentFail.Capture(context.Background(), bb, mm); err == nil || rec.State == contract.Succeeded || rec.EvidenceDigests["partial_payload_sha256"] == "" {
		t.Fatal("parent fsync failure reported success")
	}
}

func int64ptr(v int64) *int64 { return &v }
func mutateCall(f func(*Adapter, *contract.RunBinding, *contract.SourceManifest), a *Adapter, b *contract.RunBinding, m *contract.SourceManifest) (contract.Receipt, error) {
	f(a, b, m)
	return a.Capture(context.Background(), *b, *m)
}

func TestPolicyAndInventoryRejectBeforeDestination(t *testing.T) {
	for _, tc := range []struct{ name, path, component string }{{"traversal", "../data.db", "blockstore"}, {"secret", "signer-key.db", "blockstore"}, {"component", "data.db", "signer"}} {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			src := filepath.Join(base, "src")
			if err := os.Mkdir(src, 0o700); err != nil {
				t.Fatal(err)
			}
			dst := filepath.Join(base, "dst")
			m := contract.SourceManifest{Frozen: true, Backend: "fixture", Layout: "single", BackendVersion: "v1", Components: []string{tc.component}, Files: []contract.ExportFile{{Path: tc.path, SHA256: strings.Repeat("0", 64), Size: 1}}}
			_, err := Copy(context.Background(), src, dst, m, Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{tc.path}, Backend: "fixture", Layout: "single", BackendVersion: "v1", MaxBytes: 10})
			if err == nil {
				t.Fatal("expected rejection")
			}
			if _, e := os.Stat(dst); !os.IsNotExist(e) {
				t.Fatal("destination created before validation")
			}
		})
	}
}

func TestCopyRejectsHashMismatchAndRetainsPartialDestination(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src")
	dst := filepath.Join(base, "dst")
	_ = os.Mkdir(src, 0o700)
	_ = os.WriteFile(filepath.Join(src, "data.db"), []byte("changed"), 0o600)
	m := contract.SourceManifest{Frozen: true, Backend: "fixture", Layout: "single", BackendVersion: "v1", Components: []string{"blockstore"}, Files: []contract.ExportFile{{Path: "data.db", SHA256: strings.Repeat("0", 64), Size: 7}}}
	_, copyErr := Copy(context.Background(), src, dst, m, Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{"data.db"}, Backend: "fixture", Layout: "single", BackendVersion: "v1", MaxBytes: 20})
	if copyErr == nil {
		t.Fatal("expected hash mismatch")
	}
	if _, err := os.Stat(filepath.Join(dst, "data.db")); err != nil {
		t.Fatalf("partial destination should be preserved: %v (copy error: %v)", err, copyErr)
	}
}

func TestSourceTreeRejectsLinksSpecialAndExtras(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink", "fifo", "extra", "emptydir"} {
		t.Run(kind, func(t *testing.T) {
			base := t.TempDir()
			src := filepath.Join(base, "src")
			dst := filepath.Join(base, "dst")
			_ = os.Mkdir(src, 0700)
			body := []byte("listed")
			_ = os.WriteFile(filepath.Join(src, "listed.db"), body, 0600)
			p := fixturePolicy("listed.db")
			m := fixtureManifest("listed.db", body, p)
			switch kind {
			case "symlink":
				_ = os.Symlink("listed.db", filepath.Join(src, "alias.db"))
			case "hardlink":
				_ = os.Link(filepath.Join(src, "listed.db"), filepath.Join(src, "alias.db"))
			case "fifo":
				if e := syscall.Mkfifo(filepath.Join(src, "pipe"), 0600); e != nil {
					t.Fatal(e)
				}
			case "extra":
				_ = os.WriteFile(filepath.Join(src, "extra.db"), []byte("extra"), 0600)
			case "emptydir":
				_ = os.Mkdir(filepath.Join(src, "empty"), 0700)
			}
			if _, err := Copy(context.Background(), src, dst, m, p); err == nil {
				t.Fatal("unsafe or unlisted source accepted")
			}
			if _, e := os.Stat(dst); !os.IsNotExist(e) {
				t.Fatal("destination created before inventory validation")
			}
		})
	}
}

func TestSourceRootAndFileReplacementAreRejected(t *testing.T) {
	for _, rootSwap := range []bool{true, false} {
		t.Run(map[bool]string{true: "root", false: "file"}[rootSwap], func(t *testing.T) {
			base := t.TempDir()
			src := filepath.Join(base, "src")
			dst := filepath.Join(base, "dst")
			_ = os.Mkdir(src, 0700)
			body := []byte("frozen")
			file := filepath.Join(src, "data.db")
			_ = os.WriteFile(file, body, 0600)
			p := fixturePolicy("data.db")
			m := fixtureManifest("data.db", body, p)
			ops := defaultOps()
			if rootSwap {
				ops.afterOpenSource = func() error {
					if e := os.Rename(src, filepath.Join(base, "old")); e != nil {
						return e
					}
					return os.Mkdir(src, 0700)
				}
			} else {
				ops.afterInventory = func() error {
					if e := os.Rename(file, filepath.Join(src, "old.db")); e != nil {
						return e
					}
					return os.WriteFile(file, body, 0600)
				}
			}
			if _, err := copyWithOps(context.Background(), src, dst, m, p, ops); err == nil {
				t.Fatal("replacement accepted")
			}
		})
	}
}

func TestDestinationParentSymlinkRaceRejected(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src")
	parent := filepath.Join(base, "parent")
	dest := filepath.Join(parent, "capture")
	attacker := filepath.Join(base, "attacker")
	_ = os.Mkdir(src, 0700)
	_ = os.Mkdir(parent, 0700)
	_ = os.Mkdir(attacker, 0700)
	body := []byte("x")
	_ = os.WriteFile(filepath.Join(src, "data.db"), body, 0600)
	p := fixturePolicy("data.db")
	m := fixtureManifest("data.db", body, p)
	ops := defaultOps()
	ops.afterOpenParent = func() error {
		if e := os.Rename(parent, filepath.Join(base, "moved")); e != nil {
			return e
		}
		return os.Symlink(attacker, parent)
	}
	if _, err := copyWithOps(context.Background(), src, dest, m, p, ops); err == nil {
		t.Fatal("parent replacement race accepted")
	}
	if _, err := os.Stat(filepath.Join(attacker, "capture")); !os.IsNotExist(err) {
		t.Fatal("copied into replacement parent")
	}
}

func TestSourceMutationAfterTransferIsReported(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src")
	dst := filepath.Join(base, "dst")
	_ = os.Mkdir(src, 0700)
	body := []byte("original")
	file := filepath.Join(src, "data.db")
	_ = os.WriteFile(file, body, 0600)
	p := fixturePolicy("data.db")
	m := fixtureManifest("data.db", body, p)
	ops := defaultOps()
	ops.afterCopy = func() error { return os.WriteFile(file, []byte("modified"), 0600) }
	if _, err := copyWithOps(context.Background(), src, dst, m, p, ops); err == nil {
		t.Fatal("source mutation after transfer was not reported")
	}
	copied, err := os.ReadFile(filepath.Join(dst, "data.db"))
	if err != nil || string(copied) != string(body) {
		t.Fatalf("retained transfer bytes=%q err=%v", copied, err)
	}
}

func TestPreflightAndDurabilityFailuresPreserveEvidence(t *testing.T) {
	for _, stage := range []string{"space", "file-sync", "directory-sync", "parent-sync", "cancel"} {
		t.Run(stage, func(t *testing.T) {
			base := t.TempDir()
			src := filepath.Join(base, "src")
			dst := filepath.Join(base, "dst")
			_ = os.Mkdir(src, 0700)
			body := make([]byte, 256*1024)
			for i := range body {
				body[i] = 'x'
			}
			_ = os.WriteFile(filepath.Join(src, "data.db"), body, 0600)
			p := fixturePolicy("data.db")
			m := fixtureManifest("data.db", body, p)
			ops := defaultOps()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch stage {
			case "space":
				ops.available = func(string) (int64, error) { return 1, nil }
			case "file-sync":
				ops.syncFile = func(*os.File) error { return errors.New("injected file sync") }
			case "directory-sync":
				ops.syncDestination = func(*os.Root) error { return errors.New("injected directory sync") }
			case "parent-sync":
				ops.syncParent = func(*os.Root, string) error { return errors.New("injected parent sync") }
			case "cancel":
				ops.wrapWriter = func(w io.Writer) io.Writer { return &cancelAfterWrite{Writer: w, cancel: cancel} }
			}
			if _, err := copyWithOps(ctx, src, dst, m, p, ops); err == nil {
				t.Fatal("injected failure accepted")
			}
			if stage == "space" {
				if _, e := os.Stat(dst); !os.IsNotExist(e) {
					t.Fatal("space preflight created destination")
				}
				return
			}
			if _, e := os.Stat(filepath.Join(dst, "data.db")); e != nil {
				t.Fatalf("partial evidence not preserved: %v", e)
			}
		})
	}
}

func TestQuotaOverflowRejectedBeforeDestination(t *testing.T) {
	base := t.TempDir()
	src := filepath.Join(base, "src")
	dst := filepath.Join(base, "dst")
	_ = os.Mkdir(src, 0700)
	p := fixturePolicy("a.db")
	m := fixtureManifest("a.db", []byte("123456"), p)
	m.Files = append(m.Files, contract.ExportFile{Path: "b.db", SHA256: strings.Repeat("0", 64), Size: 6})
	p.AllowedFiles = append(p.AllowedFiles, "b.db")
	p.MaxBytes = 10
	if _, err := Copy(context.Background(), src, dst, m, p); err == nil {
		t.Fatal("quota overflow accepted")
	}
	if _, err := os.Stat(dst); !os.IsNotExist(err) {
		t.Fatal("quota failure created destination")
	}
}

func TestPolicyProjectsOnlyVerifiedArtifactInventory(t *testing.T) {
	binding := contract.RunBinding{Heights: contract.Heights{Blockstore: 9, App: 8, Consensus: int64ptr(9), FirstRepaired: 10}}
	a := catalog.RecoveryArtifact{ScenarioID: "scenario", Backend: "fixture", BackendVersion: "v1", Layout: "legacy", Heights: binding.Heights, FirstRepairedBlock: 10, Files: []catalog.ArtifactFile{{Path: "db/data.db", SHA256: strings.Repeat("a", 64), Size: 17, Component: "blockstore"}, {Path: "db/wal.db", SHA256: strings.Repeat("b", 64), Size: 3, Component: "wal"}}}
	p, err := PolicyFromVerifiedArtifact(a, binding, 100, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.AllowedFiles) != 2 || len(p.AllowedComponents) != 2 || len(p.ExpectedFiles) != 2 || p.BackendVersion != "v1" {
		t.Fatalf("incomplete artifact projection: %#v", p)
	}
	a.Files[1].Path = "db/other.db"
	if p.AllowedFiles[1] == a.Files[1].Path {
		t.Fatal("policy mutated with artifact")
	}
	wrong := contract.SourceManifest{Frozen: true, Backend: p.Backend, Layout: p.Layout, BackendVersion: p.BackendVersion, Components: append([]string(nil), p.AllowedComponents...), Files: append([]contract.ExportFile(nil), p.ExpectedFiles...)}
	wrong.Files[0].SHA256 = strings.Repeat("c", 64)
	if err := validatePolicy(wrong, p); err == nil {
		t.Fatal("manifest bytes not matching artifact hash were permitted")
	}
	a.Heights.FirstRepaired++
	if _, err := PolicyFromVerifiedArtifact(a, binding, 100, 2); err == nil {
		t.Fatal("artifact height mismatch accepted")
	}
}

type cancelAfterWrite struct {
	io.Writer
	cancel context.CancelFunc
	once   bool
}

func (w *cancelAfterWrite) Write(p []byte) (int, error) {
	n, e := w.Writer.Write(p)
	if !w.once {
		w.once = true
		w.cancel()
	}
	return n, e
}
func fixturePolicy(file string) Policy {
	return Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{file}, Backend: "fixture", Layout: "single", BackendVersion: "v1", MaxBytes: 2 << 20}
}
func fixtureManifest(file string, b []byte, p Policy) contract.SourceManifest {
	sum := sha256.Sum256(b)
	return contract.SourceManifest{Frozen: true, Backend: p.Backend, Layout: p.Layout, BackendVersion: p.BackendVersion, Components: []string{"blockstore"}, Files: []contract.ExportFile{{Path: file, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(b))}}}
}
func defaultOps() copyOps {
	return copyOps{syncFile: func(f *os.File) error { return f.Sync() }, syncDestination: syncTree, syncParent: func(r *os.Root, _ string) error { return syncRootHandle(r) }, available: availableBytes}
}
