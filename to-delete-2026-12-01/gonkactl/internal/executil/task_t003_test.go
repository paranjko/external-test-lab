package executil_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/executil"
	"github.com/paranjko/external-test-lab/gonkactl/internal/network"
	"github.com/paranjko/external-test-lab/gonkactl/internal/operation"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestTask_T003(t *testing.T) {
	runner := executil.NewRunner()
	result, err := runner.Run(context.Background(), contracts.ProcessSpec{Executable: "/bin/sh", Args: []string{"-c", "echo unsafe"}})
	if err == nil || result.ExitCode != 0 {
		t.Fatal("shell execution must be rejected before launch")
	}
	result, err = runner.Run(context.Background(), contracts.ProcessSpec{Executable: "/bin/printf", Args: []string{"abcdef"}, OutputLimitBytes: 3})
	if err != nil || string(result.Stdout) != "abc" || !result.Truncated {
		t.Fatalf("bounded argv result = %#v, %v", result, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = runner.Run(ctx, contracts.ProcessSpec{Executable: "/bin/true"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation error = %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer server.Close()
	client := network.NewHTTPClient(server.Client())
	if _, err := client.Get(context.Background(), server.URL); err == nil {
		t.Fatal("plaintext HTTP must be rejected outside an explicit test client")
	}
	client.AllowHTTPForTests = true
	response, err := client.Get(context.Background(), server.URL)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("loopback test HTTP = %v, %v", response, err)
	}
	_ = response.Body.Close()

	fake := operation.NewFakeClock(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	if err := fake.Wait(context.Background(), time.Second); err != nil || !fake.Now().Equal(time.Date(2026, 1, 1, 0, 0, 1, 0, time.UTC)) {
		t.Fatal("fake clock must advance deterministic waits")
	}
	_, err = runner.Run(context.Background(), contracts.ProcessSpec{Executable: "docker", Args: strings.Fields("--host tcp://remote.example ps")})
	if err == nil {
		t.Fatal("remote docker must be rejected")
	}

	receiptPath := filepath.Join(t.TempDir(), "C02.code-test.json")
	manifestPath := filepath.Join(filepath.Dir(receiptPath), "environment.json")
	if err := os.WriteFile(manifestPath, []byte(`{"kind":"portable","identity":"unit","evidence_mode":"code_contract","fixture_manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GONKACTL_TEST_RECEIPT", receiptPath)
	t.Setenv("GONKACTL_TEST_ENV", manifestPath)
	t.Setenv("GONKACTL_TEST_ID", "C02.code")
	t.Setenv("GONKACTL_EXPECTED_COMMIT", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	t.Setenv("GONKACTL_WORKING_TREE_SHA256", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
	t.Setenv("GONKACTL_TEST_COMMAND_JSON", `["go","test"]`)
	t.Setenv("GONKACTL_TEST_CWD", "/workspace/gonkactl")
	first, err := support.WriteArtifact("test-output", []byte("sanitized output"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := support.WriteArtifact("assertion-results", []byte("sanitized assertions"))
	if err != nil {
		t.Fatal(err)
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", []support.Check{{ID: "local_io", Status: "pass", Observed: "bounded", EvidenceArtifactIDs: []string{first.ID, second.ID}}}, []support.Artifact{first, second}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(receiptPath); err != nil {
		t.Fatalf("atomic receipt missing: %v", err)
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", []support.Check{{ID: "local_io", Status: "pass", Observed: "bounded", EvidenceArtifactIDs: []string{first.ID, second.ID}}}, []support.Artifact{first, second}); err == nil {
		t.Fatal("receipt helper overwrote an existing receipt")
	}
}
