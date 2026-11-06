package bootstrap

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
)

func releaseFixture(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile("../../../net-deployment-runbook/profiles/releases/v2026.10.06.lock")
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

type composeFixtureTransport struct{ calls int }

func (f *composeFixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	f.calls++
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("services: {}\n# " + r.URL.Path + "\n"))}, nil
}

func TestProfileRefreshesComposeAtExactCommit(t *testing.T) {
	base, err := Parse(fixture(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	commit := strings.Repeat("a", 40)
	profile := strings.Replace(string(releaseFixture(t)), "GONKA_COMMIT=136041c81ea8ff38e7620d76af66a7c7fe7eec50", "GONKA_COMMIT="+commit, 1)
	transport := NewTransport()
	source := &composeFixtureTransport{}
	transport.Client.Transport = source
	updated, err := transport.ApplyProfile(context.Background(), base, []byte(profile))
	if err != nil {
		t.Fatal(err)
	}
	var software Software
	if err := DecodeJSON(updated.Software, &software); err != nil {
		t.Fatal(err)
	}
	if software.Deployment.Commit != commit || source.calls != len(software.Deployment.ComposeFiles) {
		t.Fatal("deployment source not refreshed")
	}
	for _, file := range software.Deployment.ComposeFiles {
		want := strings.TrimPrefix(digestOf("services: {}\n# /gonka-ai/gonka/"+commit+"/"+file.Path+"\n"), "sha256:")
		if file.SHA256 != want {
			t.Fatal("Compose digest did not bind exact source bytes")
		}
	}
}

func TestCurrentReleaseProfileMatchesPublishedSoftware(t *testing.T) {
	base, err := Parse(fixture(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := NewTransport().ApplyProfile(context.Background(), base, releaseFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	var before, after any
	if err := json.Unmarshal(base.Software, &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(updated.Software, &after); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Fatal("current release profile changed the approved software recipe")
	}
	if !reflect.DeepEqual(base.Seeds, updated.Seeds) || !reflect.DeepEqual(base.Brokers, updated.Brokers) {
		t.Fatal("profile modified network discovery fields")
	}
	// Updating only the explicitly supplied image must preserve the model and
	// all service roles that are owned by other composition layers.
	profile := strings.Replace(string(releaseFixture(t)), "MLNODE_GENERIC_IMAGE=ghcr.io/gonka-ai/mlnode:3.0.16@", "MLNODE_GENERIC_IMAGE=ghcr.io/gonka-ai/mlnode:3.0.17@", 1)
	changed, err := NewTransport().ApplyProfile(context.Background(), base, []byte(profile))
	if err != nil {
		t.Fatal(err)
	}
	var oldSoftware, newSoftware Software
	json.Unmarshal(base.Software, &oldSoftware)
	json.Unmarshal(changed.Software, &newSoftware)
	if newSoftware.Components["mlnode"].Version != "3.0.17" {
		t.Fatal("release field not updated")
	}
	var oldModel, newModel any
	if err := json.Unmarshal(oldSoftware.Model, &oldModel); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(newSoftware.Model, &newModel); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(oldModel, newModel) || oldSoftware.Components["grafana"] != newSoftware.Components["grafana"] {
		t.Fatal("non-release layer changed")
	}
}

func TestProfileRefusesAmbiguityAndShell(t *testing.T) {
	for _, raw := range []string{"A=1\nA=2", "A=$(id)", "A=`id`", "source other.lock", "export A=1", "A=1;id", "A='unterminated", "LAB_CANDIDATE=true"} {
		if _, err := ParseProfile([]byte(raw)); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
	base, err := Parse(fixture(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	for name, profile := range map[string]string{
		"missing values": "PROFILE_SCOPE=existing-host-stack",
		"unmapped image": string(releaseFixture(t)) + "\nUNKNOWN_IMAGE=some:latest\n",
		"mutable image":  strings.Replace(string(releaseFixture(t)), "TMKMS_IMAGE=ghcr.io/product-science/tmkms-softsign-with-keygen:0.2.15@sha256:c3b6c4aaa73e93944dda4f08db8edd1a48544ad35d740cfca2dd8f3d9835aa21", "TMKMS_IMAGE=tmkms:latest", 1),
		"mutable commit": strings.Replace(string(releaseFixture(t)), "GONKA_COMMIT=136041c81ea8ff38e7620d76af66a7c7fe7eec50", "GONKA_COMMIT=main", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := NewTransport().ApplyProfile(context.Background(), base, []byte(profile)); err == nil {
				t.Fatal("invalid profile accepted")
			}
		})
	}
	base.Software = nil
	if _, err := NewTransport().ApplyProfile(context.Background(), base, releaseFixture(t)); err == nil {
		t.Fatal("incomplete recipe silently invented")
	}
}
