package coregate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type testBlockDecoder struct{ block HPlusOneBlockHeader }

func (d testBlockDecoder) DecodeHPlusOneBlock(_ context.Context, raw []byte) (HPlusOneBlockHeader, error) {
	if len(raw) == 0 {
		return HPlusOneBlockHeader{}, errors.New("truncated block")
	}
	return d.block, nil
}

func writeEvidence(t *testing.T, dir, name string, data []byte) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestFileEvidenceReaderPreservesInspectorAndLocalMapping(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(inspectorFixture)
	writeEvidence(t, dir, "inspector.json", raw)
	sum := sha256.Sum256(raw)
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "local-run", BindingDigest: strings.Repeat("a", 64), Nodes: map[string]string{"genesis": dir}, SourceDigests: map[string]map[string]string{"genesis": {"inspector.json": hex.EncodeToString(sum[:])}}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	state, err := r.ReadApplication(context.Background(), "genesis")
	if err != nil {
		t.Fatal(err)
	}
	if state.Node != "genesis" || state.Store != "application" || state.RunID != "local-run" || state.BindingDigest != strings.Repeat("a", 64) || state.Height != 370 {
		t.Fatalf("unexpected mapped state: %+v", state)
	}
	_, got, digest, err := r.ReadInspector("genesis")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(raw) || digest.SHA256 != hex.EncodeToString(sum[:]) || digest.Size != int64(len(raw)) {
		t.Fatal("saved inspector bytes or digest changed")
	}
}

func TestFileEvidenceReaderRejectsSubstitutionAndOversize(t *testing.T) {
	dir := t.TempDir()
	writeEvidence(t, dir, "inspector.json", []byte(inspectorFixture))
	wrong := sha256.Sum256([]byte("different source"))
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("b", 64), Nodes: map[string]string{"genesis": dir}, SourceDigests: map[string]map[string]string{"genesis": {"inspector.json": hex.EncodeToString(wrong[:])}}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = r.ReadInspector("genesis"); err == nil || !strings.Contains(err.Error(), "differs from local source mapping") {
		t.Fatalf("expected substituted source rejection, got %v", err)
	}
	r.limits.InspectorJSON = 8
	if _, _, _, err = r.ReadInspector("genesis"); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected bounded read rejection, got %v", err)
	}
}

func TestFileEvidenceReaderBlocksWithoutRawCommitAndValidatorBytes(t *testing.T) {
	dir := t.TempDir()
	writeEvidence(t, dir, "inspector.json", []byte(inspectorFixture))
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("c", 64), Nodes: map[string]string{"genesis": dir}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	_, err = r.ReadBlockStore(context.Background(), "genesis", 370)
	if !errors.Is(err, ErrEvidenceUnavailable) || !strings.Contains(err.Error(), "raw seen-commit bytes") {
		t.Fatalf("expected blocked raw proof gap, got %v", err)
	}
}

func TestFileEvidenceReaderKeepsHPlusOneBytesOpaqueAndBarrierJSONUntrusted(t *testing.T) {
	dir := t.TempDir()
	block := []byte{0x00, 0xff, 0x01, 0x7f}
	barrier := []byte(`{"claim":"stopped"}`)
	writeEvidence(t, dir, "h-plus-one.block", block)
	writeEvidence(t, dir, "barriers.json", barrier)
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("d", 64), Nodes: map[string]string{"n": dir}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	got, d, err := r.ReadHPlusOneBlock("n")
	if err != nil || string(got) != string(block) || d.SHA256 == "" {
		t.Fatalf("block bytes not preserved: %x %+v %v", got, d, err)
	}
	got, _, err = r.ReadBarrierJSON("n")
	if err != nil || string(got) != string(barrier) {
		t.Fatalf("barrier bytes not preserved: %s %v", got, err)
	}
	if _, err = r.VerifyCommitBarriers(context.Background(), "n", 370, "block"); !errors.Is(err, ErrEvidenceUnavailable) {
		t.Fatalf("untrusted JSON promoted to receipt: %v", err)
	}
}

func TestVerifyHPlusOneLinkChecksHeightChainAndPriorAppHash(t *testing.T) {
	dir := t.TempDir()
	writeEvidence(t, dir, "h-plus-one.block", []byte("opaque encoded block"))
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("d", 64), Nodes: map[string]string{"n": dir}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	w := Expected{Height: 370, ChainID: "synthetic", AppHash: testAppHash}
	good := HPlusOneBlockHeader{Height: 371, ChainID: w.ChainID, BlockID: testHPlusOneBlockID, PartSetHash: testPartSetHash, PartSetTotal: 1, HeaderAppHash: w.AppHash, PreviousBlockID: w.BlockID, PreviousPartSetHash: w.BlockIDPartSetHash, PreviousPartSetTotal: w.BlockIDPartSetTotal}
	if got, digest, err := r.VerifyHPlusOneLink(context.Background(), "n", w, testBlockDecoder{good}); err != nil || got != good || digest.SHA256 == "" {
		t.Fatalf("valid linkage rejected: %+v %+v %v", got, digest, err)
	}
	for name, mutate := range map[string]func(*HPlusOneBlockHeader){
		"wrong height":                 func(b *HPlusOneBlockHeader) { b.Height++ },
		"wrong chain":                  func(b *HPlusOneBlockHeader) { b.ChainID = "other" },
		"wrong prior app hash":         func(b *HPlusOneBlockHeader) { b.HeaderAppHash = testPriorAppHash },
		"invalid canonical block hash": func(b *HPlusOneBlockHeader) { b.BlockID = "not-a-digest" },
	} {
		t.Run(name, func(t *testing.T) {
			bad := good
			mutate(&bad)
			if _, _, err := r.VerifyHPlusOneLink(context.Background(), "n", w, testBlockDecoder{bad}); err == nil {
				t.Fatalf("expected linkage rejection: %+v", bad)
			}
		})
	}
}

func TestRawCommitAndValidatorSetBytesRemainExactForVersionedVerifier(t *testing.T) {
	dir := t.TempDir()
	commit := []byte{0x08, 0x01} // intentionally truncated Comet protobuf; parser lives in the versioned verifier
	wrongValidatorSet := []byte{0x0a, 0x01, 0xff}
	writeEvidence(t, dir, "seen_commit.bin", commit)
	writeEvidence(t, dir, "validator_set.bin", wrongValidatorSet)
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("e", 64), Nodes: map[string]string{"n": dir}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	gotCommit, commitDigest, gotSet, setDigest, commitErr, setErr := r.ReadRawStoreEvidence("n")
	if commitErr != nil || setErr != nil || string(gotCommit) != string(commit) || string(gotSet) != string(wrongValidatorSet) {
		t.Fatalf("raw bytes changed: commit=%x set=%x errs=%v/%v", gotCommit, gotSet, commitErr, setErr)
	}
	if commitDigest.SHA256 == setDigest.SHA256 || commitDigest.Size != int64(len(commit)) || setDigest.Size != int64(len(wrongValidatorSet)) {
		t.Fatalf("raw byte digests or sizes unexpected: %+v %+v", commitDigest, setDigest)
	}
}
