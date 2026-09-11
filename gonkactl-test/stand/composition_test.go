package stand

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPreflightCompositionBindsExactPreparedInputsAndRejectsMismatch(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte("config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), []byte("services: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	digest, err := compositionDigest(filepath.Join(dir, "config.yaml"), filepath.Join(dir, "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := PreflightComposition(dir, digest, filepath.Join(dir, "accepted.json"))
	if err != nil || accepted.Outcome != "accepted" || accepted.LaunchAttempted {
		t.Fatalf("accepted=%+v err=%v", accepted, err)
	}
	rejected, err := PreflightComposition(dir, "bad", filepath.Join(dir, "rejected.json"))
	if !errors.Is(err, ErrCompositionDigestMismatch) || rejected.Outcome != "rejected_digest_mismatch" || rejected.LaunchAttempted || rejected.ResourcesCreated {
		t.Fatalf("rejected=%+v err=%v", rejected, err)
	}
}
