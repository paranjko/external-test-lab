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
	profile, err := LoadProfile(filepath.Join("..", "environments", "proposed-compatible-devshard-baseline-v6.json"))
	if err != nil {
		t.Fatal(err)
	}
	if profile.Baseline.Status != "unqualified" {
		t.Fatalf("baseline status=%s", profile.Baseline.Status)
	}
	if profile.Adapters[0].Status == "qualified" || profile.Adapters[1].Status == "qualified" {
		t.Fatal("v3/v4 must not be inferred from v5 fixture")
	}
	if profile.Adapters[0].Reason == "" || profile.Adapters[1].Reason == "" {
		t.Fatal("v3/v4 must retain explicit unsupported gaps")
	}
	for _, adapter := range profile.Adapters[:2] {
		if adapter.UnqualifiedContract.Basis != "v5_only_fixture" || len(adapter.UnqualifiedContract.Unknown) != 7 {
			t.Fatalf("%s non-support contract=%+v", adapter.Protocol, adapter.UnqualifiedContract)
		}
	}
	v5 := profile.Adapters[2]
	if v5.Chat.Path != "/v1/chat/completions" || v5.Chat.NonStreamExpectedStatus != http.StatusOK || v5.Chat.SSETermination != "[DONE]" || v5.Chat.MalformedExpectedStatus != http.StatusBadRequest {
		t.Fatalf("v5 chat contract=%+v", v5.Chat)
	}
	if v5.Negative.MissingRouteExpectedStatus != http.StatusNotFound || len(v5.Negative.BrokenMockAcceptedOutcomes) == 0 {
		t.Fatalf("v5 negative contract=%+v", v5.Negative)
	}
}

func TestProposedBaselineProfileIsInitiallyUnqualifiedAndPinsV5Contract(t *testing.T) {

	profile, err := LoadProfile(filepath.Join("..", "environments", "proposed-compatible-devshard-baseline-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	if profile.EnvironmentID != "proposed-compatible-devshard-baseline-v1" || profile.Backend.SourceRevision != "ea44ab00ac777a98c705e033819b50ac690a82b2" || profile.Baseline.Status != "unqualified" {
		t.Fatalf("profile does not preserve the proposed baseline boundary: %+v", profile)
	}
	v5 := profile.Adapters[2]
	if v5.Health.Path != "/v5/healthz" || v5.Chat.Path != "/v1/chat/completions" || v5.Negative.MissingRoutePath != "/v5/m0-a09-missing-route" {
		t.Fatalf("v5 compatibility contract=%+v", v5)
	}
}

func TestProfileRejectsUnexplainedUnsupportedAdapter(t *testing.T) {
	profile, err := LoadProfile(filepath.Join("..", "environments", "lab-mock-devshard-testenv-v5.json"))
	if err != nil {
		t.Fatal(err)
	}
	profile.Adapters[0].Reason = ""
	if err := profile.Validate(); err == nil {
		t.Fatal("accepted v3 without an explicit unsupported gap")
	}
	profile, err = LoadProfile(filepath.Join("..", "environments", "proposed-compatible-devshard-baseline-v6.json"))
	if err != nil {
		t.Fatal(err)
	}
	profile.Adapters[0].UnqualifiedContract.Unknown = profile.Adapters[0].UnqualifiedContract.Unknown[:6]
	if err := profile.Validate(); err == nil {
		t.Fatal("accepted v3 without complete route/error/SSE gap contract")
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
