package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// These tests exercise GitHub transport, not a second bootstrap validator.
// Network behavior is tested by the installed-CLI lifecycle and bootstrap suites.
func TestBootstrapActionTransport(t *testing.T) {
	if _, err := exec.LookPath("make"); err != nil {
		t.Fatal("make is required for Action acceptance")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	makefile := filepath.Join(root, ".github/actions/gonkactl-bootstrap/Makefile")
	for _, tc := range []struct {
		name string
		code int
		body string
	}{
		{"pass", 0, `{"schema_version":1,"results":[{"chain_id":"fixture","ok":true}]}`},
		{"validation", 1, `{"schema_version":1,"results":[{"chain_id":"fixture","ok":false}]}`},
		{"execution", 2, ""},
		{"malformed", 0, "not json"},
		{"inconsistent", 0, `{"schema_version":1,"results":[{"chain_id":"fixture","ok":false}]}`},
		{"wrong-network", 0, `{"schema_version":1,"results":[{"chain_id":"other","ok":true}]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			binary := filepath.Join(dir, "gonkactl")
			body := fmt.Sprintf("#!/bin/sh\n[ \"$1 $2 $3\" = 'bootstrap validate fixture' ] || exit 97\nprintf '%%s\\n' '%s'\nexit %d\n", tc.body, tc.code)
			if err := os.WriteFile(binary, []byte(body), 0700); err != nil {
				t.Fatal(err)
			}
			report := filepath.Join(dir, "report.json")
			output := filepath.Join(dir, "output")
			cmd := exec.Command("make", "-f", makefile, "validate")
			cmd.Dir = dir
			cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir, "GITHUB_OUTPUT=" + output,
				"BOOTSTRAP_CHAIN_ID=fixture", "BOOTSTRAP_BINARY=" + binary, "BOOTSTRAP_REPORT=" + report,
				"BOOTSTRAP_INVENTORY=" + dir, "BOOTSTRAP_ORIGIN=https://example.test", "BOOTSTRAP_TIMEOUT=10s"}
			log, runErr := cmd.CombinedOutput()
			wantFail := tc.name != "pass"
			if (runErr != nil) != wantFail {
				t.Fatalf("error=%v output=%s", runErr, log)
			}
			raw, err := os.ReadFile(report)
			if err != nil {
				t.Fatal(err)
			}
			var parsed struct {
				Results []struct{ OK bool }
			}
			if err := json.Unmarshal(raw, &parsed); err != nil || len(parsed.Results) != 1 || parsed.Results[0].OK == wantFail {
				t.Fatalf("invalid transported report: %s (%v)", raw, err)
			}
			outputs, err := os.ReadFile(output)
			if err != nil || !strings.Contains(string(outputs), fmt.Sprintf("failed=%t\n", wantFail)) {
				t.Fatalf("outputs=%s err=%v", outputs, err)
			}
		})
	}
}

func TestBootstrapActionInventory(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "bootstrap/examples"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.json", "b.json", "examples/fixture.json"} {
		if err := os.WriteFile(filepath.Join(dir, "bootstrap", name), []byte(`{}`), 0600); err != nil {
			t.Fatal(err)
		}
	}
	output := filepath.Join(dir, "output")
	cmd := exec.Command("make", "-f", filepath.Join(root, ".github/actions/gonkactl-bootstrap/Makefile"), "inventory")
	cmd.Dir = dir
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir, "GITHUB_OUTPUT=" + output}
	if log, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, log)
	}
	raw, err := os.ReadFile(output)
	if err != nil || string(raw) != "chains=[\"a\",\"b\"]\n" {
		t.Fatalf("inventory=%s err=%v", raw, err)
	}
}

func TestBootstrapActionNotificationIsolation(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	reports := filepath.Join(dir, "net-deployment-runbook/.data/bootstrap-monitor")
	bin := filepath.Join(dir, "bin")
	for _, path := range []string{reports, bin} {
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, chain := range []string{"a", "b", "healthy"} {
		data := fmt.Sprintf(`{"results":[{"chain_id":%q,"bootstrap_url":"https://example.test/bootstrap.json","ok":%t}]}`, chain, chain == "healthy")
		if err := os.WriteFile(filepath.Join(reports, chain+".json"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Replace the only external write. First POST fails; the next must still run.
	transport := "#!/bin/bash\nset -eu\nwhile (($#)); do\nif [[ $1 == --data-binary ]]; then shift; printf '%s\\n' \"$1\" >> \"$TEST_POSTS\"; fi\nshift\ndone\nif [[ $(wc -l < \"$TEST_POSTS\") == 1 ]]; then echo 'secret:synthetic' >&2; exit 22; fi\nprintf '%s\\n' '{\"ok\":true}'\n"
	if err := os.WriteFile(filepath.Join(bin, "curl"), []byte(transport), 0700); err != nil {
		t.Fatal(err)
	}
	posts := filepath.Join(dir, "posts")
	cmd := exec.Command("make", "-f", filepath.Join(root, ".github/actions/gonkactl-bootstrap/Makefile"), "notify")
	cmd.Dir = dir
	cmd.Env = []string{"PATH=" + bin + ":/usr/bin:/bin", "HOME=" + dir, "TEST_POSTS=" + posts,
		"GDC_TELEGRAM_BOT_TOKEN=123:synthetic", "GDC_TELEGRAM_NOTIFICATION=-456", "GITHUB_REPOSITORY=owner/repo", "GITHUB_RUN_ID=789"}
	log, runErr := cmd.CombinedOutput()
	if runErr == nil || strings.Contains(string(log), "synthetic") {
		t.Fatalf("notification error or secret handling: %v %s", runErr, log)
	}
	raw, err := os.ReadFile(posts)
	if err != nil || strings.Count(string(raw), "\n") != 2 {
		t.Fatalf("expected one POST per failed network, no retries: %s %v", raw, err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var payload map[string]string
		if err := json.Unmarshal([]byte(line), &payload); err != nil || payload["chat_id"] != "-456" || payload["parse_mode"] != "HTML" {
			t.Fatalf("bad POST payload: %s %v", line, err)
		}
	}
}
