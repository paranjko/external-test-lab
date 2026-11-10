package legacyv1

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func TestTask_T011(t *testing.T) {
	valid := archive(t, []tar.Header{{Name: "mnemonics", Typeflag: tar.TypeDir}, {Name: "remote-state", Typeflag: tar.TypeDir}, {Name: "remote-state/tmkms", Typeflag: tar.TypeDir}, {Name: "manifest.json", Typeflag: tar.TypeReg, Size: 2}}, [][]byte{nil, nil, nil, []byte("{}")})
	if _, err := Scan(bytes.NewReader(valid)); err != nil {
		t.Fatalf("valid USTAR = %v", err)
	}
	link := archive(t, []tar.Header{{Name: "remote-state", Typeflag: tar.TypeDir}, {Name: "remote-state/tmkms", Typeflag: tar.TypeDir}, {Name: "remote-state/tmkms/link", Typeflag: tar.TypeSymlink, Linkname: "/outside"}}, [][]byte{nil, nil, nil})
	if _, err := Scan(bytes.NewReader(link)); !errors.Is(err, ErrInvalidArchive) {
		t.Fatalf("link = %v", err)
	}
	duplicate := archive(t, []tar.Header{{Name: "manifest.json", Typeflag: tar.TypeReg, Size: 2}, {Name: "manifest.json", Typeflag: tar.TypeReg, Size: 2}}, [][]byte{[]byte("{}"), []byte("{}")})
	if _, err := Scan(bytes.NewReader(duplicate)); !errors.Is(err, ErrInvalidArchive) {
		t.Fatalf("duplicate = %v", err)
	}
	file := &memorySnapshotFile{data: valid, sha: Digest(valid)}
	archiveValue, err := ScanSnapshot(context.Background(), memorySnapshot{file: file}, contracts.SnapshotRequest{})
	if err != nil || archiveValue.SnapshotSHA256 != file.sha {
		t.Fatalf("snapshot scan = %#v, %v", archiveValue, err)
	}
	state := model.SigningState{Height: "0009007199254740993", Round: "0002", Step: -1}
	verified := model.VerifiedArchive{Archive: archiveValue, NodeName: "node1", ChainID: "gonka-devnet-community", GenesisSHA256: "abc", SigningState: state}
	if verified.SigningState.Height != state.Height || verified.SigningState.Round != state.Round || verified.SigningState.BlockID != nil {
		t.Fatalf("DTO distinction lost: %#v", verified.SigningState)
	}
	block := &model.BlockID{Hash: "hash", PartsTotal: 7, PartsHash: "parts"}
	verified.SigningState.BlockID = block
	if verified.SigningState.BlockID != block || verified.SigningState.BlockID.PartsTotal != 7 {
		t.Fatalf("block ID distinction lost: %#v", verified.SigningState)
	}
}

func FuzzArchiveHeaders(f *testing.F) {
	f.Add([]byte("not a tar"))
	f.Add(make([]byte, 1024))
	f.Fuzz(func(t *testing.T, input []byte) {
		_, _ = Scan(bytes.NewReader(input))
	})
}

func archive(t *testing.T, headers []tar.Header, bodies [][]byte) []byte {
	t.Helper()
	var result bytes.Buffer
	writer := tar.NewWriter(&result)
	for index := range headers {
		if err := writer.WriteHeader(&headers[index]); err != nil {
			t.Fatal(err)
		}
		if len(bodies[index]) > 0 {
			if _, err := writer.Write(bodies[index]); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return result.Bytes()
}

type memorySnapshot struct{ file *memorySnapshotFile }

func (s memorySnapshot) Copy(context.Context, contracts.SnapshotRequest) (contracts.SnapshotFile, error) {
	return s.file, nil
}

type memorySnapshotFile struct {
	data []byte
	sha  string
}

func (f *memorySnapshotFile) Path() string     { return "memory" }
func (f *memorySnapshotFile) SHA256() string   { return f.sha }
func (f *memorySnapshotFile) SizeBytes() int64 { return int64(len(f.data)) }
func (f *memorySnapshotFile) Open() (io.ReadCloser, error) {
	return io.NopCloser(bytes.NewReader(f.data)), nil
}
func (f *memorySnapshotFile) Close() error { return nil }
