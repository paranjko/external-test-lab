package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReleaseFeatureDiscoveryAndBindings(t *testing.T) {
	cases, err := discoverReleaseScenarios(filepath.Join("..", "..", "feature"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) != 20 {
		t.Fatalf("found %d scenarios, want 20", len(cases))
	}
	bound := 0
	for _, item := range cases {
		name := filepath.Base(item.Feature)
		if item.FeatureSHA != releaseFeatureHashes[name] {
			t.Fatalf("reviewed feature digest changed: %s", name)
		}
		if releaseV5Bindings[name+": "+item.Name] != "" {
			bound++
		}
	}
	if bound != 6 {
		t.Fatalf("found %d release-safe bindings, want 6", bound)
	}
}

func TestReleaseRejectsChangedFeatureBeforeFixture(t *testing.T) {
	root := t.TempDir()
	featureDir := filepath.Join(root, "feature")
	if err := os.Mkdir(featureDir, 0o700); err != nil {
		t.Fatal(err)
	}
	feature := "Feature: modified\n  Scenario: A quiet escrow sends heartbeats after a floor is seeded\n    Given a changed input\n"
	if err := os.WriteFile(filepath.Join(featureDir, "devshard_v5_height_sync.feature"), []byte(feature), 0o600); err != nil {
		t.Fatal(err)
	}
	dir, err := executeRelease(context.Background(), releaseOptions{
		Tag: "devshard/v5.0.0", SHA256: releaseV5ArchiveSHA,
		Features: featureDir, DataRoot: filepath.Join(root, "build", "report"),
	})
	if err == nil || !strings.Contains(err.Error(), "feature digest mismatch") {
		t.Fatalf("changed feature was not rejected: %v", err)
	}
	if dir == "" {
		t.Fatal("rejection has no retained report")
	}
	b, err := os.ReadFile(filepath.Join(dir, "report.json"))
	if err != nil {
		t.Fatal(err)
	}
	var report releaseReport
	if err := json.Unmarshal(b, &report); err != nil {
		t.Fatal(err)
	}
	if report.Cleanup.Completed != true || report.Cases[0].Status != "not_run" || report.Archive != "" {
		t.Fatalf("rejection receipt is inconsistent: %+v", report)
	}
	if _, err := os.Stat(filepath.Join(dir, "source")); !os.IsNotExist(err) {
		t.Fatalf("source fixture was created on digest mismatch: %v", err)
	}
}

func TestReleaseOverlayRequiresReviewedHooks(t *testing.T) {
	root := t.TempDir()
	harness := filepath.Join(root, "devshard", "testenv", "citest", "harness")
	if err := os.MkdirAll(harness, 0o700); err != nil {
		t.Fatal(err)
	}
	config := "versiond:\n  mode: multi\n  version_name: v2\n  binary_version: 0.2.13-v2-r2\n"
	stack := "workDir, err := os.MkdirTemp(testenvDir, prefix)\nfixComposePaths(t, s.ComposePath, s.TestenvDir)\ns.upAfterCatalog(t, false)\ns.upAfterCatalog(t, false)\n"
	if err := os.WriteFile(filepath.Join(harness, "config.go"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(harness, "stack.go"), []byte(stack), 0o600); err != nil {
		t.Fatal(err)
	}
	overlay, err := prepareReleaseOverlay(root, t.TempDir(), "owned-run")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(overlay); err != nil {
		t.Fatal(err)
	}
	patched, err := os.ReadFile(filepath.Join(filepath.Dir(overlay), "overlay-stack.go"))
	if err != nil {
		t.Fatal(err)
	}
	for _, fragment := range []string{"MOCK_DAPI_VERSION_NAME", "MOCK_DAPI_VERSION_SHA256", "captureReleaseChildIdentity(t, s)", "sha256sum /proc/$1/exe"} {
		if !strings.Contains(string(patched), fragment) {
			t.Fatalf("release overlay is missing %q", fragment)
		}
	}
	if err := os.WriteFile(filepath.Join(harness, "config.go"), []byte("changed contract"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareReleaseOverlay(root, t.TempDir(), "owned-run"); err == nil {
		t.Fatal("changed upstream contract was accepted")
	}
}

func TestReleaseReportRendersStepsLogsAndIdentity(t *testing.T) {
	root := t.TempDir()
	report := releaseReport{
		SchemaVersion: "1.0.0",
		ReleaseTag:    "devshard/v5.0.0",
		Cases: []releaseScenario{{
			Feature: "feature/example.feature", Name: "A released child serves chat",
			Steps:  []string{"the user sends chat", "chat succeeds"},
			Status: "upstream_pass", Log: "test-chat.jsonl",
		}},
		RuntimeIdentities: []string{"child-identity-chat.txt"},
	}
	if err := writeReleaseReport(root, report); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(root, "index.html"))
	if err != nil {
		t.Fatal(err)
	}
	for _, fragment := range []string{"A released child serves chat", "the user sends chat", "chat succeeds", "test-chat.jsonl", "child-identity-chat.txt"} {
		if !strings.Contains(string(b), fragment) {
			t.Fatalf("rendered report is missing %q", fragment)
		}
	}
}
