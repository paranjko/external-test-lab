package main

import (
	"path/filepath"
	"testing"
)

func TestOutputRootIgnoresInternalTestDataRoot(t *testing.T) {
	dataRoot := t.TempDir()
	t.Setenv("DATA_ROOT", "")
	t.Setenv("GONKACTL_TEST_DATA_ROOT", dataRoot)
	root := outputRoot("clean-run")
	want := filepath.Join("build", "report", "results", "clean-run")
	if root != want {
		t.Fatalf("root=%q want=%q", root, want)
	}
}

func TestOutputRootDefaultsBelowCurrentDirectory(t *testing.T) {
	t.Setenv("DATA_ROOT", "")
	t.Setenv("GONKACTL_TEST_DATA_ROOT", "")
	root := outputRoot("clean-run")
	want := filepath.Join("build", "report", "results", "clean-run")
	if root != want {
		t.Fatalf("root=%q want=%q", root, want)
	}
}

func TestOutputRootUsesOperatorDataRoot(t *testing.T) {
	dataRoot := t.TempDir()
	t.Setenv("DATA_ROOT", dataRoot)
	t.Setenv("GONKACTL_TEST_DATA_ROOT", "other-root")
	root := outputRoot("clean-run")
	want := filepath.Join(dataRoot, "results", "clean-run")
	if root != want {
		t.Fatalf("root=%q want=%q", root, want)
	}
}
