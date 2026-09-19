package code

import (
	"bytes"
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/legacyv1"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_B04_Code(t *testing.T) {
	raw := []byte(`{"z":"café","app_version":"legacy","app_hash":null,"initial_height":7,"consensus":{"params":{"escape":"<>&","unicode":"é","number":1.0}}}`)
	want := []byte("{\n  \"app_hash\": \"\",\n  \"consensus_params\": {\n    \"escape\": \"<>&\",\n    \"number\": 1.0,\n    \"unicode\": \"é\"\n  },\n  \"initial_height\": \"7\",\n  \"z\": \"café\"\n}\n")
	got, canonicalDigest, err := legacyv1.CanonicalGenesis(raw)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("canonical golden mismatch: %q %v", got, err)
	}
	if canonicalDigest == legacyv1.RawBootstrapDigest(raw) {
		t.Fatal("raw and canonical digest must be separate")
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, err := support.WriteArtifact("test-output", []byte("canonical_jq_golden=matched\nraw_bootstrap_digest=separate\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("unicode=preserved\nescaping=jq-compatible\nnumbers=preserved\n"))
	if err != nil {
		t.Fatal(err)
	}
	golden, err := support.WriteArtifact("canonical-golden-comparison", append(append([]byte(nil), got...), []byte("sha256="+canonicalDigest+"\n")...))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{{ID: "independent_jq_canonical_golden_bytes", Status: "pass", Observed: "frozen jq-compatible bytes matched", EvidenceArtifactIDs: []string{golden.ID}}, {ID: "unicode_escaping_number_contract", Status: "pass", Observed: "Unicode, escaping and numeric token golden matched", EvidenceArtifactIDs: []string{assertions.ID}}, {ID: "raw_bootstrap_digest_separate", Status: "pass", Observed: "raw bytes digest differs from canonical digest", EvidenceArtifactIDs: []string{output.ID}}}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, assertions, golden}); err != nil {
		t.Fatal(err)
	}
}
