package evidence

import (
	"bytes"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestDiffIsCanonicalAndDistinguishesAbsentFromEmpty(t *testing.T) {
	before := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "z", Entries: []contract.Entry{{Key: []byte("b"), Value: []byte("old")}, {Key: []byte("a"), Value: []byte{}}}}, {Name: "a"}}}
	after := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "z", Entries: []contract.Entry{{Key: []byte("c"), Value: []byte("new")}, {Key: []byte("a"), Value: []byte{}}}}, {Name: "a"}}}
	changes, err := Diff(before, after)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 2 || changes[0].Store != "z" || string(changes[0].Key) != "b" || !changes[0].Before.Present || changes[0].After.Present {
		t.Fatalf("unexpected first diff: %#v", changes)
	}
	if string(changes[1].Key) != "c" || changes[1].Before.Present || !changes[1].After.Present {
		t.Fatalf("empty/absent conflated: %#v", changes[1])
	}
	reversed, err := Diff(after, before)
	if err != nil {
		t.Fatal(err)
	}
	if len(reversed) != 2 || reversed[0].Before.Present || !reversed[0].After.Present {
		t.Fatalf("inverse diff incorrect: %#v", reversed)
	}
}

func TestDiffRejectsMissingStoresAndDuplicateKeys(t *testing.T) {
	if _, err := Diff(contract.Snapshot{}, contract.Snapshot{}); err == nil {
		t.Fatal("empty store inventory accepted")
	}
	_, err := Diff(contract.Snapshot{Stores: []contract.LogicalStore{{Name: "present"}}}, contract.Snapshot{Stores: []contract.LogicalStore{{Name: "other"}}})
	if err == nil {
		t.Fatal("missing store accepted")
	}
	_, err = Diff(contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k")}, {Key: []byte("k")}}}}}, contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s"}}})
	if err == nil {
		t.Fatal("duplicate key accepted")
	}
	_, err = validateAllowlist([]contract.Change{{Store: "s", Key: []byte("k")}, {Store: "s", Key: []byte("k")}})
	if err == nil {
		t.Fatal("duplicate allowlist key accepted")
	}
}

func TestSnapshotDigestNormalizesNilAndEmptyPresentValues(t *testing.T) {
	a := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: nil}}}}}
	b := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte{}}}}}}
	da, err := SnapshotDigest(a)
	if err != nil {
		t.Fatal(err)
	}
	db, err := SnapshotDigest(b)
	if err != nil {
		t.Fatal(err)
	}
	if da != db {
		t.Fatal("nil and empty present value encoded differently")
	}
}

func TestEvaluateRequiresExactChangesAndCompleteMatchingReceipts(t *testing.T) {
	o := validOracle(t)
	result := Evaluate(o)
	if result.Verdict != contract.Pass {
		t.Fatalf("valid oracle verdict=%s reason=%s", result.Verdict, result.Reason)
	}

	missing := o
	missing.Receipts = nil
	if got := Evaluate(missing); got.Verdict != contract.Inconclusive {
		t.Fatalf("missing receipt verdict=%s", got.Verdict)
	}

	stale := o
	stale.Receipts = append([]contract.Receipt(nil), o.Receipts...)
	stale.Receipts[0].BindingDigest = "stale"
	if got := Evaluate(stale); got.Verdict != contract.Inconclusive {
		t.Fatalf("stale receipt verdict=%s", got.Verdict)
	}

	wrongRun := o
	wrongRun.Receipts = append([]contract.Receipt(nil), o.Receipts...)
	wrongRun.Receipts[0].RunID = "other"
	if got := Evaluate(wrongRun); got.Verdict != contract.Inconclusive {
		t.Fatalf("wrong run verdict=%s", got.Verdict)
	}
	unresolved := o
	unresolved.Receipts = append([]contract.Receipt(nil), o.Receipts[:len(o.Receipts)-1]...)
	if got := Evaluate(unresolved); got.Verdict != contract.Inconclusive {
		t.Fatalf("unresolved receipt intent verdict=%s", got.Verdict)
	}
	failed := o
	failed.Receipts = append([]contract.Receipt(nil), o.Receipts...)
	failed.Receipts[3].State = contract.Failed
	if got := Evaluate(failed); got.Verdict != contract.Inconclusive {
		t.Fatalf("failed receipt verdict=%s", got.Verdict)
	}
	noChain := o
	noChain.Receipts = append([]contract.Receipt(nil), o.Receipts...)
	noChain.Receipts[1].Predecessor = "broken"
	if got := Evaluate(noChain); got.Verdict != contract.Inconclusive {
		t.Fatalf("broken receipt chain verdict=%s", got.Verdict)
	}

	forbidden := o
	forbidden.Domains = append([]contract.DomainEvidence(nil), o.Domains...)
	for i := range forbidden.Domains {
		if forbidden.Domains[i].Domain == contract.Migration {
			// Invert an otherwise allowed key while retaining the approved forward change.
			forbidden.Domains[i].After.Stores[0].Entries[0].Value = []byte("forbidden")
		}
	}
	if got := Evaluate(forbidden); got.Verdict != contract.Fail {
		t.Fatalf("forbidden-key inverse change verdict=%s reason=%s", got.Verdict, got.Reason)
	}
	omitted := o
	omitted.RequiredStores = []string{"s", "missing"}
	if got := Evaluate(omitted); got.Verdict == contract.Pass {
		t.Fatal("snapshot missing an inventory store passed")
	}
	peerMismatch := o
	peerMismatch.PeerBinding = peerMismatch.Binding
	if got := Evaluate(peerMismatch); got.Verdict != contract.Fail {
		t.Fatalf("same run treated as independent: %s", got.Verdict)
	}
	deltaMismatch := o
	deltaMismatch.PeerPostState = &contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte("different")}}}}}
	if got := Evaluate(deltaMismatch); got.Verdict != contract.Fail || got.MigrationEqual {
		t.Fatalf("independent computed delta mismatch result=%#v", got)
	}
	peerMissing := o
	peerMissing.PeerPreState = &contract.Snapshot{Stores: []contract.LogicalStore{{Name: "other"}}}
	peerMissing.PeerPostState = &contract.Snapshot{Stores: []contract.LogicalStore{{Name: "other"}}}
	if got := Evaluate(peerMissing); got.Verdict == contract.Pass {
		t.Fatal("peer snapshots omitting required store passed")
	}
}

func TestEvaluatePreviewCannotPass(t *testing.T) {
	o := validOracle(t)
	o.Preview = true
	got := Evaluate(o)
	if got.Verdict == contract.Pass || got.Qualification != "not_run" {
		t.Fatalf("preview result=%#v", got)
	}
}

func TestEvaluateRequiresConsensusHeight(t *testing.T) {
	o := validOracle(t)
	o.Binding.Heights.Consensus = nil
	if got := Evaluate(o); got.Verdict == contract.Pass {
		t.Fatal("missing consensus height passed")
	}
}

func TestEvaluateDomainOrderingIsCanonical(t *testing.T) {
	o := validOracle(t)
	a := Evaluate(o)
	for i, j := 0, len(o.Domains)-1; i < j; i, j = i+1, j-1 {
		o.Domains[i], o.Domains[j] = o.Domains[j], o.Domains[i]
	}
	b := Evaluate(o)
	if a.Verdict != b.Verdict || len(a.Domains) != len(b.Domains) {
		t.Fatal("result changed with domain input order")
	}
	for i := range a.Domains {
		if a.Domains[i].Domain != b.Domains[i].Domain {
			t.Fatalf("domain order %v != %v", a.Domains, b.Domains)
		}
	}
}

func TestRenderRedactsAndIsDeterministic(t *testing.T) {
	r := Result{SchemaVersion: Version, Verdict: contract.Inconclusive, Qualification: "pending", Reason: "secret=abc /srv/private/export source=/home/ilyar/secret", Domains: []DomainResult{{Domain: contract.Migration, Changes: []contract.Change{{Store: "auth", Key: []byte("key"), Before: contract.Value{Present: true, Bytes: []byte("password=hunter2")}}}}}, Receipts: []contract.Receipt{{RunID: "private-run-id", Phase: contract.Run, State: contract.Succeeded, Operation: "/secret/path", EvidenceDigests: map[string]string{"/private/path": strings.Repeat("f", 64)}, Reason: "token=hidden"}}}
	first, err := Render(r)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Render(r)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.JSON, second.JSON) || !bytes.Equal(first.Markdown, second.Markdown) {
		t.Fatal("report output is not deterministic")
	}
	for _, forbidden := range [][]byte{[]byte("abc"), []byte("/srv/private"), []byte("/home/ilyar"), []byte("hunter2"), []byte("private-run-id"), []byte("/secret/path"), []byte("/private/path"), []byte("hidden")} {
		if bytes.Contains(first.JSON, forbidden) || bytes.Contains(first.Markdown, forbidden) {
			t.Fatalf("report leaked %q", forbidden)
		}
	}
}

func TestEvaluateFreshComputesDeltasFromSnapshots(t *testing.T) {
	in := freshInput(t)
	got := EvaluateFresh(in)
	if got.Verdict != contract.Pass || got.Qualification != "evidence_verified" || len(got.Domains) != 3 || !got.MigrationEqual {
		t.Fatalf("fresh evaluation=%#v", got)
	}
	for _, d := range got.Domains {
		if d.Domain == contract.Migration && (len(d.Changes) != 1 || !d.Allowed) {
			t.Fatalf("migration was not computed from snapshots: %#v", d)
		}
	}
}

func TestEvaluateFreshRejectsMissingProducerAndTamperedSnapshot(t *testing.T) {
	in := freshInput(t)
	missing := in
	missing.MainProducerReceipts = nil
	if got := EvaluateFresh(missing); got.Verdict == contract.Pass {
		t.Fatal("missing producer receipts passed")
	}
	tampered := in
	tampered.Domains = append([]FreshDomain(nil), in.Domains...)
	for i := range tampered.Domains {
		if tampered.Domains[i].Domain == contract.Migration {
			tampered.Domains[i].After.Stores[0].Entries[0].Value = []byte("tampered")
		}
	}
	if got := EvaluateFresh(tampered); got.Verdict == contract.Pass {
		t.Fatal("tampered snapshot passed")
	}
	noPolicy := in
	noPolicy.MainPolicy.Allowlist = map[contract.Domain][]ExpectedChange{contract.Topology: {}}
	if got := EvaluateFresh(noPolicy); got.Verdict == contract.Pass {
		t.Fatal("missing signed policy domain passed")
	}
}

func TestFreshPayloadDigestDoesNotIncludeReceipts(t *testing.T) {
	r := Result{SchemaVersion: Version, Verdict: contract.Pass, Qualification: "evidence_verified", Receipts: []contract.Receipt{{RunID: "first"}}}
	a, err := FreshPayloadDigest(r)
	if err != nil {
		t.Fatal(err)
	}
	r.Receipts = []contract.Receipt{{RunID: "second"}}
	b, err := FreshPayloadDigest(r)
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Fatal("receipt-free payload digest changed with receipt chain")
	}
	r.ProducerEvidenceDigest = strings.Repeat("c", 64)
	c, err := FreshPayloadDigest(r)
	if err != nil {
		t.Fatal(err)
	}
	if c == a {
		t.Fatal("producer evidence digest is not pinned by fresh result payload")
	}
}

func freshInput(t *testing.T) FreshInput {
	t.Helper()
	base := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte("before")}}}}}
	changed := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte("after")}}}}}
	policy := AuthenticatedPolicy{CatalogDigest: strings.Repeat("a", 64), ArtifactDigest: strings.Repeat("b", 64), RequiredStores: []string{"s"}, Allowlist: map[contract.Domain][]ExpectedChange{
		contract.Topology: {}, contract.Block: {}, contract.Migration: {{Store: "s", Key: []byte("k"), BeforePresent: true, BeforeSHA256: hashValue([]byte("before")), AfterPresent: true, AfterSHA256: hashValue([]byte("after"))}},
	}}
	binding := validOracle(t).Binding
	binding.InputDigests = map[string]string{"catalog": policy.CatalogDigest, "recovery_artifact": policy.ArtifactDigest}
	peer := binding
	peer.RunID, peer.Workspace, peer.OwnershipMarker = "fresh-peer", "/tmp/fresh-peer", "peer-owner"
	domains := []FreshDomain{{contract.Topology, base, base}, {contract.Migration, base, changed}, {contract.Block, base, base}}
	mainExpected := producerSnapshotDigests(domains)
	peerExpected := producerSnapshotDigests([]FreshDomain{{contract.Migration, base, changed}})
	return FreshInput{SchemaVersion: Version, Binding: binding, PeerBinding: peer, Domains: domains, PeerMigrationBefore: base, PeerMigrationAfter: changed,
		MainProducerReceipts: producerReceiptsFor(t, binding, mainExpected), PeerProducerReceipts: producerReceiptsFor(t, peer, peerExpected), MainPolicy: policy, PeerPolicy: policy}
}

func producerReceiptsFor(t *testing.T, binding contract.RunBinding, expected map[contract.Phase]map[string]string) []contract.Receipt {
	return producerReceiptsForPhases(t, binding, expected, []contract.Phase{contract.Capture, contract.Stage, contract.Run})
}

func producerReceiptsForPhases(t *testing.T, binding contract.RunBinding, expected map[contract.Phase]map[string]string, phases []contract.Phase) []contract.Receipt {
	t.Helper()
	digest, err := contract.Digest(binding)
	if err != nil {
		t.Fatal(err)
	}
	receipts := []contract.Receipt{}
	previous := ""
	sequence := uint64(1)
	for _, phase := range phases {
		want, ok := expected[phase]
		if !ok {
			t.Fatal("missing expected phase", phase)
		}
		want = cloneDigestMap(want)
		want["payload"] = strings.Repeat("e", 64)
		intent := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest, Phase: phase, Operation: string(phase), State: contract.Running, Sequence: sequence, Predecessor: previous}
		result := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest, Phase: phase, Operation: string(phase), State: contract.Succeeded, Sequence: sequence + 1, Predecessor: digestReceipt(intent), EvidenceDigests: want}
		receipts = append(receipts, intent, result)
		previous = digestReceipt(result)
		sequence += 2
	}
	return receipts
}

func cloneDigestMap(m map[string]string) map[string]string {
	out := make(map[string]string, len(m)+1)
	for k, v := range m {
		out[k] = v
	}
	return out
}

func TestEvaluateFreshRequiresOrderedFullPeerProducerChain(t *testing.T) {
	in := freshInput(t)
	if got := EvaluateFresh(in); got.Verdict != contract.Pass {
		t.Fatalf("complete peer capture/stage/run chain rejected: %#v", got)
	}
	expected := producerSnapshotDigests(in.Domains)
	in.MainProducerReceipts = producerReceiptsForPhases(t, in.Binding, expected, []contract.Phase{contract.Stage, contract.Capture, contract.Run})
	if got := EvaluateFresh(in); got.Verdict == contract.Pass {
		t.Fatal("out-of-order producer phases passed")
	}
}

func validOracle(t *testing.T) Oracle {
	t.Helper()
	binding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "r-1", Scenario: contract.Scenario,
		Workspace: "/tmp/rehearsal", OwnershipMarker: "owner-1", ChainID: "test-chain",
		GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 2, App: 1, Consensus: int64ptr(2), FirstRepaired: 2},
		BlockID: "block-id", AppHash: "app-hash", AppHashHeight: 1, ToolVersion: "test", CatalogVersion: "test",
		InputDigests: map[string]string{"source": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"node": "image@sha256:" + strings.Repeat("c", 64)},
	}
	base := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte("before")}}}}}
	changed := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "s", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte("after")}}}}}
	change := contract.Change{Store: "s", Key: []byte("k"), Before: contract.Value{Present: true, Bytes: []byte("before")}, After: contract.Value{Present: true, Bytes: []byte("after")}}
	domains := []contract.DomainEvidence{
		{Domain: contract.Topology, Before: base, After: base, Allowlist: []contract.Change{}},
		{Domain: contract.Migration, Before: base, After: changed, Allowlist: []contract.Change{change}},
		{Domain: contract.Block, Before: base, After: base, Allowlist: []contract.Change{}},
	}
	peerBinding := binding
	peerBinding.RunID = "r-2"
	peerBinding.Workspace = "/tmp/rehearsal-2"
	peerBinding.OwnershipMarker = "owner-2"
	mainEvidence := map[string]string{}
	for _, d := range domains {
		for _, side := range []struct {
			name string
			s    contract.Snapshot
		}{{"before", d.Before}, {"after", d.After}} {
			value, e := SnapshotDigest(side.s)
			if e != nil {
				t.Fatal(e)
			}
			mainEvidence[string(d.Domain)+"."+side.name] = value
		}
	}
	peerEvidence := map[string]string{}
	for _, side := range []struct {
		name string
		s    contract.Snapshot
	}{{"migration.before", base}, {"migration.after", changed}} {
		value, e := SnapshotDigest(side.s)
		if e != nil {
			t.Fatal(e)
		}
		peerEvidence[side.name] = value
	}
	peer := receiptsFor(t, binding, mainEvidence)
	peerReceipts := receiptsFor(t, peerBinding, peerEvidence)
	return Oracle{SchemaVersion: Version, Binding: binding, Domains: domains, RequiredStores: []string{"s"}, Receipts: peer, PeerBinding: peerBinding, PeerPreState: &base, PeerPostState: &changed, PeerReceipts: peerReceipts}
}

func receiptsFor(t *testing.T, binding contract.RunBinding, verifyEvidence map[string]string) []contract.Receipt {
	t.Helper()
	digest, err := contract.Digest(binding)
	if err != nil {
		t.Fatal(err)
	}
	receipts := []contract.Receipt{}
	previous := ""
	for i, phase := range []contract.Phase{contract.Capture, contract.Stage, contract.Run, contract.Verify} {
		evidence := map[string]string{"result": strings.Repeat("d", 64)}
		if phase == contract.Verify {
			evidence = verifyEvidence
		}
		intent := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest, Phase: phase, Operation: string(phase), State: contract.Running, Sequence: uint64(2*i + 1), Predecessor: previous}
		result := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest, Phase: phase, Operation: string(phase), State: contract.Succeeded, Sequence: uint64(2*i + 2), EvidenceDigests: evidence}
		result.Predecessor, err = contract.Digest(intent)
		if err != nil {
			t.Fatal(err)
		}
		receipts = append(receipts, intent, result)
		previous, err = contract.Digest(result)
		if err != nil {
			t.Fatal(err)
		}
	}
	return receipts
}

func int64ptr(v int64) *int64 { return &v }
