package stand

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestProfilePinsCandidateAndRefusesUnsupportedQualification(t *testing.T) {
	profile, err := LoadProfile(filepath.Join("..", "environments", "lab-mock-devshard-testenv-v5.json"))
	if err != nil {
		t.Fatal(err)
	}
	if profile.Baseline.Status != "unqualified" {
		t.Fatalf("baseline status=%s", profile.Baseline.Status)
	}
	if profile.Adapters[0].Status == "qualified" || profile.Adapters[1].Status == "qualified" {
		t.Fatal("v3/v4 must not be inferred from v5 fixture")
	}
}

func TestLeaseIsExclusiveAndCannotUseSystemTemp(t *testing.T) {
	root := filepath.Join("..", "build", "gonkactl-test", "stand-test-leases")
	lease, err := AcquireLease(root, "lab-mock", "case-a")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lease.Release() })
	if _, err := AcquireLease(root, "lab-mock", "case-a"); !errors.Is(err, ErrLeaseHeld) {
		t.Fatalf("err=%v, want ErrLeaseHeld", err)
	}
	if _, err := AcquireLease(os.TempDir(), "lab-mock", "case-b"); err == nil {
		t.Fatal("accepted system temporary root")
	}
}

func TestLeaseReleaseRequiresOwnerToken(t *testing.T) {
	root := filepath.Join("..", "build", "gonkactl-test", "stand-test-leases")
	lease, err := AcquireLease(root, "lab-mock", "case-b")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lease.Release() })
	forged := lease
	forged.Token = "not-the-owner"
	if err := forged.Release(); err == nil {
		t.Fatal("forged owner released lease")
	}
}

func TestVersionedHealthIsNotInferenceEvidence(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v5/healthz" {
			t.Fatalf("path=%s", request.URL.Path)
		}
		writer.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	adapter := Adapter{Protocol: "v5"}
	adapter.Health.Path = "/v5/healthz"
	adapter.Health.ExpectedStatus = http.StatusOK
	result := ProbeHealth(context.Background(), NewProbeClient(), server.URL, adapter)
	if result.Outcome != "passed" || result.ActualStatus != http.StatusOK {
		t.Fatalf("result=%+v", result)
	}
	if result.URL == "" || result.Protocol != "v5" {
		t.Fatalf("missing route evidence: %+v", result)
	}
}

func TestHealthFailureIsBlocked(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	adapter := Adapter{Protocol: "v5"}
	adapter.Health.Path = "/v5/healthz"
	adapter.Health.ExpectedStatus = http.StatusOK
	result := ProbeHealth(context.Background(), NewProbeClient(), server.URL, adapter)
	if result.Outcome != "blocked" || result.ActualStatus != http.StatusServiceUnavailable {
		t.Fatalf("result=%+v", result)
	}
}
