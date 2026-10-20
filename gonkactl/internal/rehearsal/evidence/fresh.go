package evidence

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// ExpectedChange is the public, hash-only projection of a signed change policy.
// It deliberately does not carry raw store values into the policy layer.
type ExpectedChange struct {
	Store         string `json:"store"`
	Key           []byte `json:"key"`
	BeforePresent bool   `json:"before_present"`
	BeforeSHA256  string `json:"before_sha256,omitempty"`
	AfterPresent  bool   `json:"after_present"`
	AfterSHA256   string `json:"after_sha256,omitempty"`
}

// AuthenticatedPolicy is a projection supplied only after the session layer
// has authenticated the catalog/artifact. EvaluateFresh checks that the
// asserted payload digests are the ones bound to each run; it does not perform
// signature verification itself.
type AuthenticatedPolicy struct {
	CatalogDigest  string                               `json:"catalog_digest"`
	ArtifactDigest string                               `json:"artifact_digest"`
	RequiredStores []string                             `json:"required_stores"`
	Allowlist      map[contract.Domain][]ExpectedChange `json:"allowlist"`
}

type FreshDomain struct {
	Domain contract.Domain   `json:"domain"`
	Before contract.Snapshot `json:"before"`
	After  contract.Snapshot `json:"after"`
}

// FreshInput contains producer evidence only; no Verify receipt is accepted or
// needed. The session layer remains responsible for authenticating policies
// and source/runtime provenance before constructing this input.
type FreshInput struct {
	SchemaVersion        string              `json:"schema_version"`
	Binding              contract.RunBinding `json:"binding"`
	PeerBinding          contract.RunBinding `json:"peer_binding"`
	Domains              []FreshDomain       `json:"domains"`
	PeerMigrationBefore  contract.Snapshot   `json:"peer_migration_before"`
	PeerMigrationAfter   contract.Snapshot   `json:"peer_migration_after"`
	MainProducerReceipts []contract.Receipt  `json:"main_producer_receipts"`
	PeerProducerReceipts []contract.Receipt  `json:"peer_producer_receipts"`
	MainPolicy           AuthenticatedPolicy `json:"main_policy"`
	PeerPolicy           AuthenticatedPolicy `json:"peer_policy"`
}

// EvaluateFresh independently computes every logical-store delta and checks
// it against the hash-only authenticated policy projections. PASS means only
// that supplied evidence is internally consistent; it is not runtime
// qualification or acceptance by Gonka Core.
func EvaluateFresh(in FreshInput) Result {
	r := Result{SchemaVersion: Version, Verdict: contract.Inconclusive, Qualification: "pending"}
	if in.SchemaVersion != Version || contract.ValidateBinding(in.Binding) != nil || contract.ValidateBinding(in.PeerBinding) != nil {
		r.Verdict, r.Reason = contract.Fail, "schema or run binding mismatch"
		return r
	}
	if in.Binding.Heights.Consensus == nil || in.PeerBinding.Heights.Consensus == nil {
		r.Reason = "consensus height unavailable"
		return r
	}
	mainDigest, err := contract.Digest(in.Binding)
	if err != nil {
		r.Reason = "binding digest unavailable"
		return r
	}
	r.BindingDigest = mainDigest
	if !independentBindingCompatible(in.Binding, in.PeerBinding) {
		r.Verdict, r.Reason = contract.Fail, "independent run binding is invalid or not distinct"
		return r
	}
	if err := validateFreshPolicy(in.Binding, in.MainPolicy); err != nil {
		r.Reason = "authenticated policy is incomplete or mismatched"
		return r
	}
	if err := validateFreshPolicy(in.PeerBinding, in.PeerPolicy); err != nil || !samePolicy(in.MainPolicy, in.PeerPolicy) {
		r.Reason = "independent authenticated policies differ or are incomplete"
		return r
	}
	required, err := validateStoreInventory(in.MainPolicy.RequiredStores)
	if err != nil {
		r.Reason = "required store inventory is invalid"
		return r
	}
	if len(in.Domains) != 3 {
		r.Reason = "all three domains are required"
		return r
	}
	seen := map[contract.Domain]bool{}
	var migration []contract.Change
	for _, d := range in.Domains {
		if d.Domain != contract.Topology && d.Domain != contract.Migration && d.Domain != contract.Block {
			r.Verdict, r.Reason = contract.Fail, "unknown evidence domain"
			return r
		}
		if seen[d.Domain] {
			r.Verdict, r.Reason = contract.Fail, "duplicate evidence domain"
			return r
		}
		seen[d.Domain] = true
		before, after := d.Before, d.After
		if !hasRequiredStores(before, required) || !hasRequiredStores(after, required) {
			r.Reason = "domain snapshot omits a required store"
			return r
		}
		actual, diffErr := Diff(before, after)
		if diffErr != nil {
			r.Reason = "snapshot incomplete or invalid"
			return r
		}
		policy, present := in.MainPolicy.Allowlist[d.Domain]
		if !present || policy == nil {
			r.Reason = "authenticated domain allowlist is absent"
			return r
		}
		allowed, policyErr := expectedChanges(policy)
		if policyErr != nil {
			r.Verdict, r.Reason = contract.Fail, "invalid allowlist"
			return r
		}
		matches := changesMatchExpected(actual, allowed)
		r.Domains = append(r.Domains, DomainResult{Domain: d.Domain, Changes: actual, Allowed: matches})
		if !matches {
			r.Verdict, r.Reason = contract.Fail, "observed changes do not exactly match domain allowlist"
		}
		if d.Domain == contract.Migration {
			migration = actual
		}
	}
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		if !seen[domain] {
			r.Reason = "required evidence domain missing"
			return r
		}
	}
	if !hasRequiredStores(in.PeerMigrationBefore, required) || !hasRequiredStores(in.PeerMigrationAfter, required) {
		r.Reason = "independent run snapshot omits a required store"
		return r
	}
	mainMigrationBefore := snapshotFor(in.Domains, contract.Migration, true)
	left, leftErr := SnapshotDigest(mainMigrationBefore)
	right, rightErr := SnapshotDigest(in.PeerMigrationBefore)
	if leftErr != nil || rightErr != nil {
		r.Reason = "migration pre-state incomplete"
		return r
	}
	if left != right {
		r.Verdict, r.Reason = contract.Fail, "independent migration pre-states differ"
		return r
	}
	peerDelta, err := Diff(in.PeerMigrationBefore, in.PeerMigrationAfter)
	if err != nil {
		r.Reason = "independent migration snapshots are incomplete"
		return r
	}
	r.MigrationEqual = sameChanges(migration, peerDelta)
	if !r.MigrationEqual {
		r.Verdict, r.Reason = contract.Fail, "independent migration deltas differ"
	}
	if err := validateProducerReceipts(in.Binding, mainDigest, in.MainProducerReceipts, producerSnapshotDigests(in.Domains)); err != nil {
		r.Reason = "main producer receipts are incomplete or invalid"
		return r
	}
	peerDigest, err := contract.Digest(in.PeerBinding)
	if err != nil {
		r.Reason = "independent binding digest unavailable"
		return r
	}
	peerDomains := []FreshDomain{{Domain: contract.Migration, Before: in.PeerMigrationBefore, After: in.PeerMigrationAfter}}
	if err := validateProducerReceipts(in.PeerBinding, peerDigest, in.PeerProducerReceipts, producerSnapshotDigests(peerDomains)); err != nil {
		r.Reason = "independent run receipts are incomplete or invalid"
		return r
	}
	if r.Verdict != contract.Fail {
		r.Verdict, r.Qualification, r.Reason = contract.Pass, "evidence_verified", ""
	}
	sort.Slice(r.Domains, func(i, j int) bool { return r.Domains[i].Domain < r.Domains[j].Domain })
	return r
}

func validateFreshPolicy(binding contract.RunBinding, p AuthenticatedPolicy) error {
	if !contract.IsDigest(p.CatalogDigest) || !contract.IsDigest(p.ArtifactDigest) ||
		binding.InputDigests["catalog"] != p.CatalogDigest || binding.InputDigests["recovery_artifact"] != p.ArtifactDigest {
		return errors.New("policy digest mismatch")
	}
	if _, err := validateStoreInventory(p.RequiredStores); err != nil {
		return err
	}
	for domain := range p.Allowlist {
		if domain != contract.Topology && domain != contract.Migration && domain != contract.Block {
			return errors.New("unknown policy domain")
		}
	}
	for _, d := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		if changes, ok := p.Allowlist[d]; ok {
			if changes == nil {
				return errors.New("nil allowlist")
			}
			if _, err := expectedChanges(changes); err != nil {
				return err
			}
		}
	}
	return nil
}

func expectedChanges(in []ExpectedChange) ([]ExpectedChange, error) {
	out := append([]ExpectedChange(nil), in...)
	for i := range out {
		c := &out[i]
		if c.Store == "" || (!c.BeforePresent && c.BeforeSHA256 != "") || (!c.AfterPresent && c.AfterSHA256 != "") ||
			(c.BeforePresent && !contract.IsDigest(c.BeforeSHA256)) || (c.AfterPresent && !contract.IsDigest(c.AfterSHA256)) {
			return nil, errors.New("malformed expected change")
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Store != out[j].Store {
			return out[i].Store < out[j].Store
		}
		return bytes.Compare(out[i].Key, out[j].Key) < 0
	})
	for i := 1; i < len(out); i++ {
		if out[i-1].Store == out[i].Store && bytes.Equal(out[i-1].Key, out[i].Key) {
			return nil, errors.New("duplicate expected key")
		}
	}
	return out, nil
}

func changesMatchExpected(actual []contract.Change, expected []ExpectedChange) bool {
	if len(actual) != len(expected) {
		return false
	}
	for i, c := range actual {
		e := expected[i]
		if c.Store != e.Store || !bytes.Equal(c.Key, e.Key) || c.Before.Present != e.BeforePresent || c.After.Present != e.AfterPresent {
			return false
		}
		if c.Before.Present && hashValue(c.Before.Bytes) != e.BeforeSHA256 || c.After.Present && hashValue(c.After.Bytes) != e.AfterSHA256 {
			return false
		}
	}
	return true
}

func hashValue(value []byte) string { sum := sha256.Sum256(value); return hex.EncodeToString(sum[:]) }

func samePolicy(a, b AuthenticatedPolicy) bool {
	if !sameStrings(a.RequiredStores, b.RequiredStores) {
		return false
	}
	for _, d := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		aa, aok := a.Allowlist[d]
		bb, bok := b.Allowlist[d]
		if aok != bok {
			return false
		}
		if !aok {
			continue
		}
		x, err := expectedChanges(aa)
		if err != nil {
			return false
		}
		y, err := expectedChanges(bb)
		if err != nil || len(x) != len(y) {
			return false
		}
		for i := range x {
			if x[i].Store != y[i].Store || !bytes.Equal(x[i].Key, y[i].Key) || x[i].BeforePresent != y[i].BeforePresent || x[i].BeforeSHA256 != y[i].BeforeSHA256 || x[i].AfterPresent != y[i].AfterPresent || x[i].AfterSHA256 != y[i].AfterSHA256 {
				return false
			}
		}
	}
	return true
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	aa := append([]string(nil), a...)
	bb := append([]string(nil), b...)
	sort.Strings(aa)
	sort.Strings(bb)
	for i := range aa {
		if aa[i] != bb[i] {
			return false
		}
	}
	return true
}

func snapshotFor(domains []FreshDomain, domain contract.Domain, before bool) contract.Snapshot {
	for _, d := range domains {
		if d.Domain == domain {
			if before {
				return d.Before
			}
			return d.After
		}
	}
	return contract.Snapshot{}
}

func producerSnapshotDigests(domains []FreshDomain) map[contract.Phase]map[string]string {
	out := map[contract.Phase]map[string]string{contract.Capture: {}, contract.Stage: {}, contract.Run: {}}
	for _, d := range domains {
		for _, side := range []struct {
			name  string
			snap  contract.Snapshot
			phase contract.Phase
		}{{"before", d.Before, contract.Run}, {"after", d.After, contract.Run}} {
			phase := side.phase
			if d.Domain == contract.Topology {
				if side.name == "before" {
					phase = contract.Capture
				} else {
					phase = contract.Stage
				}
			}
			digest, err := SnapshotDigest(side.snap)
			if err == nil {
				out[phase][string(d.Domain)+"."+side.name] = digest
			}
		}
	}
	return out
}

func validateProducerReceipts(binding contract.RunBinding, bindingDigest string, receipts []contract.Receipt, expected map[contract.Phase]map[string]string) error {
	if len(receipts) == 0 {
		return errors.New("producer receipts missing")
	}
	seen := map[contract.Phase]bool{}
	previousSeq := uint64(0)
	previousDigest := ""
	phaseOrder := []contract.Phase{contract.Capture, contract.Stage, contract.Run}
	phaseIndex := 0
	for i := 0; i < len(receipts); {
		intent := receipts[i]
		if contract.ValidateReceipt(intent, binding) != nil || intent.BindingDigest != bindingDigest || intent.State != contract.Running {
			return errors.New("invalid producer intent")
		}
		if intent.Sequence != previousSeq+1 || intent.Predecessor != previousDigest {
			return errors.New("invalid predecessor")
		}
		if i+1 >= len(receipts) {
			return errors.New("unresolved producer intent")
		}
		result := receipts[i+1]
		if contract.ValidateReceipt(result, binding) != nil || result.BindingDigest != bindingDigest || result.State != contract.Succeeded || result.Phase != intent.Phase || result.Operation != intent.Operation || result.Sequence != intent.Sequence+1 || result.Predecessor != digestReceipt(intent) {
			return errors.New("invalid producer result")
		}
		want, required := expected[result.Phase]
		if !required || seen[result.Phase] || phaseIndex >= len(phaseOrder) || result.Phase != phaseOrder[phaseIndex] {
			return errors.New("unexpected producer phase")
		}
		for key, digest := range want {
			if result.EvidenceDigests[key] != digest {
				return errors.New("producer does not bind snapshot")
			}
		}
		seen[result.Phase] = true
		phaseIndex++
		previousSeq = result.Sequence
		previousDigest = digestReceipt(result)
		if previousDigest == "" {
			return errors.New("receipt digest unavailable")
		}
		i += 2
	}
	for phase := range expected {
		if !seen[phase] {
			return fmt.Errorf("missing producer phase %s", phase)
		}
	}
	return nil
}

// FreshPayloadDigest excludes receipts so a Verify result can be pinned by a
// later Verify receipt without a self-referential hash cycle.
func FreshPayloadDigest(result Result) (string, error) {
	if result.SchemaVersion != Version {
		return "", errors.New("invalid fresh result version")
	}
	if result.ProducerEvidenceDigest != "" && !contract.IsDigest(result.ProducerEvidenceDigest) {
		return "", errors.New("invalid producer evidence digest")
	}
	result.Receipts = nil
	return contract.Digest(struct {
		Domain string `json:"domain"`
		Result Result `json:"result"`
	}{"rehearsal-fresh-result/v1", result})
}
