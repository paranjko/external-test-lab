package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersionAndBuildInfo(t *testing.T) {
	for _, test := range []struct{ argument, want string }{
		{"--version", version + "\n"},
		{"build-info", "version=" + version + "\ncommit=" + commit + "\nbuild_time=" + buildTime + "\n"},
	} {
		cmd := newRootCmd()
		var output bytes.Buffer
		cmd.SetOut(&output)
		cmd.SetArgs([]string{test.argument})
		if err := cmd.Execute(); err != nil {
			t.Fatal(err)
		}
		if output.String() != test.want {
			t.Fatalf("%s: got %q", test.argument, output.String())
		}
	}
	if strings.Contains(version, " ") {
		t.Fatal("invalid release version")
	}
}
