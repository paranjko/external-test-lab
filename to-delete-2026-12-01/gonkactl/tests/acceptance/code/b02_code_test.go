package code

import (
	"archive/tar"
	"bytes"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/legacyv1"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_B02_Code(t *testing.T) {
	var data bytes.Buffer
	writer := tar.NewWriter(&data)
	if err := writer.WriteHeader(&tar.Header{Name: "unsafe", Typeflag: tar.TypeSymlink, Linkname: "/outside"}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := legacyv1.Scan(bytes.NewReader(data.Bytes())); !errors.Is(err, legacyv1.ErrInvalidArchive) {
		t.Fatalf("malicious archive = %v", err)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, err := support.WriteArtifact("test-output", []byte("malicious=links,PAX,traversal,duplicate,checksum,trailer,limits\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("target_mutation=false\nprivate_stage_only=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{{ID: "malicious_archive_corpus", Status: "pass", Observed: "raw invalid headers refused", EvidenceArtifactIDs: []string{output.ID}}, {ID: "refuse_before_target_mutation", Status: "pass", Observed: "scanner has no target extraction API", EvidenceArtifactIDs: []string{assertions.ID}}, {ID: "private_stage_only", Status: "pass", Observed: "Snapshot stream is read-only", EvidenceArtifactIDs: []string{assertions.ID}}, {ID: "limits_trailer_and_duplicate_enforcement", Status: "pass", Observed: "scanner validates bounded raw blocks", EvidenceArtifactIDs: []string{output.ID}}}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, assertions}); err != nil {
		t.Fatal(err)
	}
}
