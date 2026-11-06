package contract

import (
	"strings"
	"testing"
)

func binding() RunBinding {
	h := int64(3)
	return RunBinding{SchemaVersion: Version, RunID: "run-1", Scenario: Scenario, Workspace: "/tmp/rehearsal", OwnershipMarker: "owner-1", ChainID: "test", GenesisSHA256: strings.Repeat("a", 64), Heights: Heights{Blockstore: 3, App: 2, Consensus: &h, FirstRepaired: 3}, BlockID: "block", AppHash: "app", AppHashHeight: 2, ToolVersion: "test", CatalogVersion: "1", InputDigests: map[string]string{"source": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"binary": strings.Repeat("c", 64)}, Paths: map[string]string{"source": "/tmp/rehearsal/source"}}
}

func TestBinding(t *testing.T) {
	b := binding()
	if err := ValidateSchema("binding", b); err != nil {
		t.Fatal(err)
	}
	if err := ValidateBinding(b); err != nil {
		t.Fatal(err)
	}
	original, _ := Digest(b)
	b.RunID = "run-2"
	changed, _ := Digest(b)
	if original == changed {
		t.Fatal("run ID not bound")
	}
	for _, mutate := range []func(*RunBinding){func(b *RunBinding) { b.Workspace = "/" }, func(b *RunBinding) { b.Paths["source"] = "/tmp/elsewhere" }, func(b *RunBinding) { b.RunID = "../escape" }, func(b *RunBinding) { b.GenesisSHA256 = "unverified" }, func(b *RunBinding) { b.AppHashHeight++ }} {
		b := binding()
		mutate(&b)
		if ValidateBinding(b) == nil {
			t.Fatal("accepted invalid binding")
		}
	}
}

func TestStrictJSON(t *testing.T) {
	for _, data := range []string{`{"x":1,"x":2}`, `{"x":{"a":1,"a":2}}`, `{"x":1} {}`, `{"x":1,"unknown":2}`, `{"x":`} {
		var out struct {
			X any `json:"x"`
		}
		if DecodeStrict([]byte(data), &out) == nil {
			t.Fatalf("accepted %s", data)
		}
	}
	var out struct {
		X any `json:"x"`
	}
	if err := DecodeStrict([]byte(`{"x":[{"a":1}]}`), &out); err != nil {
		t.Fatal(err)
	}
}

func TestInputBindingHasNoHashCycle(t *testing.T) {
	b := binding()
	contextBefore, _ := InputBindingDigest(b)
	fullBefore, _ := Digest(b)
	b.InputDigests["source_manifest"] = PayloadDigest([]byte("signed bytes"))
	contextAfter, _ := InputBindingDigest(b)
	fullAfter, _ := Digest(b)
	if contextBefore != contextAfter || fullBefore == fullAfter {
		t.Fatal("incorrect input/final digest domains")
	}
	b.RunID = "another-run"
	other, _ := InputBindingDigest(b)
	if other == contextAfter {
		t.Fatal("input context not run-bound")
	}
}

func TestSchemaRefusesMissingAndUnknownFields(t *testing.T) {
	for _, value := range []any{map[string]any{}, map[string]any{"unexpected": true}} {
		if ValidateSchema("binding", value) == nil {
			t.Fatal("incomplete binding accepted")
		}
	}
	if ValidateSchema("unknown", binding()) == nil {
		t.Fatal("unknown schema accepted")
	}
}

func TestTransitions(t *testing.T) {
	states := []State{Planned, Running, Succeeded, Failed, Blocked, Unknown}
	for _, from := range states {
		for _, to := range states {
			want := from == Planned && (to == Running || to == Blocked) || from == Running && (to == Succeeded || to == Failed || to == Blocked || to == Unknown)
			if CanTransition(from, to) != want {
				t.Fatalf("%s -> %s", from, to)
			}
		}
	}
	if CanTransition(Unknown, Running) {
		t.Fatal("unknown mutation replay permitted")
	}
}

func TestReceipt(t *testing.T) {
	b := binding()
	digest, _ := Digest(b)
	zero := 0
	r := Receipt{SchemaVersion: Version, RunID: b.RunID, BindingDigest: digest, Phase: Capture, Operation: "capture", State: Succeeded, Sequence: 1, ExitCode: &zero}
	if err := ValidateSchema("receipt", r); err != nil {
		t.Fatal(err)
	}
	if err := ValidateReceipt(r, b); err != nil {
		t.Fatal(err)
	}
	r.RunID = "stale"
	if ValidateReceipt(r, b) == nil {
		t.Fatal("accepted stale receipt")
	}
	r.RunID = b.RunID
	fail := 1
	r.ExitCode = &fail
	if ValidateReceipt(r, b) == nil {
		t.Fatal("accepted false success")
	}
}
