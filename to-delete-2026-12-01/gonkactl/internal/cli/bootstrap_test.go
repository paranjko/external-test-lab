package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/bootstrap"
)

func TestBootstrapCLIInvalidInputsAndJSONFailure(t *testing.T) {
	directory := t.TempDir()
	for _, suffix := range []string{"json", "env"} {
		if err := os.WriteFile(filepath.Join(directory, "fixture."+suffix), []byte("invalid"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		args   []string
		code   int
		report bool
	}{
		{[]string{"bootstrap", "validate"}, 2, false},
		{[]string{"bootstrap", "validate", "fixture", "--policy", "typo"}, 2, false},
		{[]string{"bootstrap", "update", "fixture", directory, "--policy", "typo"}, 2, false},
		{[]string{"bootstrap", "validate", "../escape", "--path", directory}, 2, false},
		{[]string{"bootstrap", "validate", "fixture", "--path", directory, "--compare-published", directory}, 2, false},
		{[]string{"bootstrap", "validate", "fixture", "--path", directory, "--timeout", "0s"}, 2, false},
		{[]string{"bootstrap", "validate", "fixture", "--path", directory, "--json"}, 1, true},
		{[]string{"bootstrap", "update", "fixture"}, 2, false},
		{[]string{"bootstrap", "update", "../escape", directory}, 2, false},
		{[]string{"bootstrap", "update", "fixture", directory, "--timeout", "0s"}, 2, false},
		{[]string{"bootstrap", "update", "fixture", directory, "--json"}, 1, true},
	} {
		root := NewRoot()
		var out bytes.Buffer
		root.SetOut(&out)
		root.SetErr(&out)
		root.SetArgs(tc.args)
		err := root.Execute()
		if ExitCode(err) != tc.code {
			t.Fatalf("args=%v err=%v", tc.args, err)
		}
		if tc.report {
			var report bootstrap.Report
			if err := json.Unmarshal(out.Bytes(), &report); err != nil {
				t.Fatal(err)
			}
			if len(report.Results) != 1 || report.Results[0].OK || report.Results[0].SoftwareDeclared != nil {
				t.Fatalf("invalid-input report: %+v", report)
			}
		}
	}
}
