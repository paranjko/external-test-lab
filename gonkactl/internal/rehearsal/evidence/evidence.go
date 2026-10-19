// Package evidence verifies frozen logical-store snapshots and produces
// redacted, deterministic rehearsal reports. It does not qualify a runtime.
package evidence

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const Version = "rehearsal-evidence/v1"

var (
	ErrInvalidSnapshot = errors.New("invalid or incomplete snapshot")
	ErrInvalidOracle   = errors.New("invalid evidence oracle")
)

// Oracle is a typed assertion over full logical snapshots. Allowlist values
// describe exact expected before/after values; they are never migration data.
type Oracle struct {
	SchemaVersion  string                    `json:"schema_version"`
	Binding        contract.RunBinding       `json:"binding"`
	Domains        []contract.DomainEvidence `json:"domains"`
	RequiredStores []string                  `json:"required_stores"`
	Receipts       []contract.Receipt        `json:"receipts"`
	Preview        bool                      `json:"preview,omitempty"`
	PeerBinding    contract.RunBinding       `json:"peer_binding"`
	PeerPreState   *contract.Snapshot        `json:"peer_pre_state,omitempty"`
	PeerPostState  *contract.Snapshot        `json:"peer_post_state,omitempty"`
	PeerReceipts   []contract.Receipt        `json:"peer_receipts"`
}

type DomainResult struct {
	Domain  contract.Domain   `json:"domain"`
	Changes []contract.Change `json:"changes"`
	Allowed bool              `json:"allowed"`
}

type Result struct {
	SchemaVersion          string             `json:"schema_version"`
	BindingDigest          string             `json:"binding_digest,omitempty"`
	ProducerEvidenceDigest string             `json:"producer_evidence_digest,omitempty"`
	Verdict                contract.Verdict   `json:"verdict"`
	Qualification          string             `json:"qualification"`
	Reason                 string             `json:"reason,omitempty"`
	Domains                []DomainResult     `json:"domains"`
	MigrationEqual         bool               `json:"migration_equal,omitempty"`
	Receipts               []contract.Receipt `json:"receipts"`
}

type Report struct {
	JSON     []byte
	Markdown []byte
}

var secretPattern = regexp.MustCompile(`(?i)(token|secret|password|mnemonic|private[_ -]?key|authorization)(\s*[:=]\s*|\s+)[^\s,;]+`)
var pathPattern = regexp.MustCompile(`(^|[=:\s])(/[^\s,;]+|~/[^\s,;]+)`)

// Diff validates both complete snapshots and returns a stable byte-exact diff.
// A nil value and an empty byte slice remain distinguishable by Present.
func Diff(before, after contract.Snapshot) ([]contract.Change, error) {
	b, err := indexSnapshot(before)
	if err != nil {
		return nil, err
	}
	a, err := indexSnapshot(after)
	if err != nil {
		return nil, err
	}
	stores := map[string]struct{}{}
	for name := range b {
		stores[name] = struct{}{}
	}
	for name := range a {
		stores[name] = struct{}{}
	}
	for name := range stores {
		if _, ok := b[name]; !ok {
			return nil, fmt.Errorf("%w: store %q missing before", ErrInvalidSnapshot, name)
		}
		if _, ok := a[name]; !ok {
			return nil, fmt.Errorf("%w: store %q missing after", ErrInvalidSnapshot, name)
		}
	}
	changes := make([]contract.Change, 0)
	for store := range stores {
		keys := map[string]struct{}{}
		for key := range b[store] {
			keys[key] = struct{}{}
		}
		for key := range a[store] {
			keys[key] = struct{}{}
		}
		for key := range keys {
			bv, bok := b[store][key]
			av, aok := a[store][key]
			if bok == aok && (!bok || bytes.Equal(bv, av)) {
				continue
			}
			changes = append(changes, contract.Change{Store: store, Key: []byte(key), Before: contract.Value{Present: bok, Bytes: clone(bv)}, After: contract.Value{Present: aok, Bytes: clone(av)}})
		}
	}
	sortChanges(changes)
	return changes, nil
}

func indexSnapshot(s contract.Snapshot) (map[string]map[string][]byte, error) {
	if len(s.Stores) == 0 {
		return nil, fmt.Errorf("%w: stores absent", ErrInvalidSnapshot)
	}
	out := make(map[string]map[string][]byte, len(s.Stores))
	for _, store := range s.Stores {
		if store.Name == "" {
			return nil, fmt.Errorf("%w: empty store name", ErrInvalidSnapshot)
		}
		if _, exists := out[store.Name]; exists {
			return nil, fmt.Errorf("%w: duplicate store %q", ErrInvalidSnapshot, store.Name)
		}
		out[store.Name] = make(map[string][]byte, len(store.Entries))
		for _, entry := range store.Entries {
			key := string(entry.Key)
			if _, exists := out[store.Name][key]; exists {
				return nil, fmt.Errorf("%w: duplicate key in store %q", ErrInvalidSnapshot, store.Name)
			}
			out[store.Name][key] = clone(entry.Value)
		}
	}
	return out, nil
}

// Evaluate checks exact domain allowlists, binding-bound receipts and an
// independent migration delta. Missing or insufficient evidence is never PASS.
func Evaluate(o Oracle) Result {
	r := Result{SchemaVersion: Version, Verdict: contract.Inconclusive, Qualification: "pending"}
	if o.Preview {
		r.Qualification = "not_run"
		r.Reason = "preview only; runtime qualification not run"
		return r
	}
	if o.SchemaVersion != Version || contract.ValidateBinding(o.Binding) != nil {
		r.Verdict, r.Reason = contract.Fail, "schema or run binding mismatch"
		return r
	}
	if o.Binding.Heights.Consensus == nil {
		r.Reason = "consensus height unavailable"
		return r
	}
	digest, err := contract.Digest(o.Binding)
	if err != nil {
		r.Reason = "binding digest unavailable"
		return r
	}
	r.BindingDigest = digest
	requiredStores, err := validateStoreInventory(o.RequiredStores)
	if err != nil {
		r.Verdict, r.Reason = contract.Fail, "required store inventory is invalid"
		return r
	}
	if len(o.Domains) != 3 {
		r.Reason = "all three domains are required"
		return r
	}
	seen := map[contract.Domain]bool{}
	var migration []contract.Change
	for _, d := range o.Domains {
		if d.Domain != contract.Topology && d.Domain != contract.Migration && d.Domain != contract.Block {
			r.Verdict, r.Reason = contract.Fail, "unknown evidence domain"
			return r
		}
		if seen[d.Domain] {
			r.Verdict, r.Reason = contract.Fail, "duplicate evidence domain"
			return r
		}
		seen[d.Domain] = true
		if !hasRequiredStores(d.Before, requiredStores) || !hasRequiredStores(d.After, requiredStores) {
			r.Reason = "domain snapshot omits a required store"
			return r
		}
		changes, diffErr := Diff(d.Before, d.After)
		if diffErr != nil {
			r.Reason = "snapshot incomplete or invalid"
			return r
		}
		allowed, listErr := validateAllowlist(d.Allowlist)
		if listErr != nil {
			r.Verdict, r.Reason = contract.Fail, "invalid allowlist"
			return r
		}
		if !sameChanges(changes, allowed) {
			r.Verdict, r.Reason = contract.Fail, "observed changes do not exactly match domain allowlist"
		}
		r.Domains = append(r.Domains, DomainResult{Domain: d.Domain, Changes: changes, Allowed: sameChanges(changes, allowed)})
		if d.Domain == contract.Migration {
			migration = changes
		}
	}
	sort.Slice(r.Domains, func(i, j int) bool { return r.Domains[i].Domain < r.Domains[j].Domain })
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		if !seen[domain] {
			r.Reason = "required evidence domain missing"
			return r
		}
	}
	if o.PeerPreState == nil || o.PeerPostState == nil || len(o.PeerReceipts) == 0 {
		if r.Verdict != contract.Fail {
			r.Reason = "independent migration comparison evidence missing"
		}
		return r
	}
	if contract.ValidateBinding(o.PeerBinding) != nil || !independentBindingCompatible(o.Binding, o.PeerBinding) {
		r.Verdict, r.Reason = contract.Fail, "independent run binding is invalid or not distinct"
		return r
	}
	if o.PeerBinding.Heights.Consensus == nil {
		r.Reason = "independent consensus height unavailable"
		return r
	}
	var migrationBefore contract.Snapshot
	for _, d := range o.Domains {
		if d.Domain == contract.Migration {
			migrationBefore = d.Before
			break
		}
	}
	left, leftErr := SnapshotDigest(migrationBefore)
	right, rightErr := SnapshotDigest(*o.PeerPreState)
	if leftErr != nil || rightErr != nil {
		r.Reason = "migration pre-state incomplete"
		return r
	}
	if !hasRequiredStores(*o.PeerPreState, requiredStores) || !hasRequiredStores(*o.PeerPostState, requiredStores) {
		r.Reason = "independent run snapshot omits a required store"
		return r
	}
	if left != right {
		r.Verdict, r.Reason = contract.Fail, "independent migration pre-states differ"
		return r
	}
	peer, peerErr := Diff(*o.PeerPreState, *o.PeerPostState)
	if peerErr != nil {
		r.Reason = "independent migration snapshots are incomplete"
		return r
	}
	r.MigrationEqual = sameChanges(migration, peer)
	if !r.MigrationEqual {
		r.Verdict, r.Reason = contract.Fail, "independent migration deltas differ"
	}
	if receiptErr := validateReceipts(o.Binding, digest, o.Receipts); receiptErr != nil {
		if r.Verdict != contract.Fail {
			r.Reason = receiptErr.Error()
		}
		return r
	}
	if err := validateSnapshotReceipts(o.Domains, o.Receipts); err != nil {
		r.Reason = err.Error()
		return r
	}
	peerDigest, err := contract.Digest(o.PeerBinding)
	if err != nil {
		r.Reason = "independent binding digest unavailable"
		return r
	}
	if receiptErr := validateReceipts(o.PeerBinding, peerDigest, o.PeerReceipts); receiptErr != nil {
		if r.Verdict != contract.Fail {
			r.Reason = "independent run receipts are incomplete or invalid"
		}
		return r
	}
	if err := validatePeerSnapshotReceipt(*o.PeerPreState, *o.PeerPostState, o.PeerReceipts); err != nil {
		r.Reason = err.Error()
		return r
	}
	r.Receipts = append([]contract.Receipt(nil), o.Receipts...)
	if r.Verdict != contract.Fail {
		r.Verdict, r.Qualification, r.Reason = contract.Pass, "evidence_verified", ""
	}
	sort.Slice(r.Domains, func(i, j int) bool { return r.Domains[i].Domain < r.Domains[j].Domain })
	return r
}

func independentBindingCompatible(a, b contract.RunBinding) bool {
	return a.RunID != b.RunID && a.Workspace != b.Workspace && a.OwnershipMarker != b.OwnershipMarker && a.Scenario == b.Scenario && a.ChainID == b.ChainID && a.GenesisSHA256 == b.GenesisSHA256 && a.Heights.Blockstore == b.Heights.Blockstore && a.Heights.App == b.Heights.App && equalInt64Pointer(a.Heights.Consensus, b.Heights.Consensus) && a.Heights.FirstRepaired == b.Heights.FirstRepaired && a.BlockID == b.BlockID && a.AppHash == b.AppHash && a.AppHashHeight == b.AppHashHeight && a.ToolVersion == b.ToolVersion && a.CatalogVersion == b.CatalogVersion && equalStringMap(a.RuntimeIdentities, b.RuntimeIdentities)
}

func equalInt64Pointer(a, b *int64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
func equalStringMap(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func validateSnapshotReceipts(domains []contract.DomainEvidence, receipts []contract.Receipt) error {
	verify, ok := receiptPhase(receipts, contract.Verify)
	if !ok {
		return errors.New("verify receipt missing")
	}
	for _, d := range domains {
		for _, side := range []struct {
			name     string
			snapshot contract.Snapshot
		}{{"before", d.Before}, {"after", d.After}} {
			key := string(d.Domain) + "." + side.name
			digest, err := SnapshotDigest(side.snapshot)
			if err != nil {
				return errors.New("snapshot digest unavailable")
			}
			if verify.EvidenceDigests[key] != digest {
				return fmt.Errorf("verify receipt does not bind %s snapshot", key)
			}
		}
	}
	return nil
}

func validatePeerSnapshotReceipt(before, after contract.Snapshot, receipts []contract.Receipt) error {
	verify, ok := receiptPhase(receipts, contract.Verify)
	if !ok {
		return errors.New("independent verify receipt missing")
	}
	for _, side := range []struct {
		name     string
		snapshot contract.Snapshot
	}{{"migration.before", before}, {"migration.after", after}} {
		digest, err := SnapshotDigest(side.snapshot)
		if err != nil {
			return errors.New("independent snapshot digest unavailable")
		}
		if verify.EvidenceDigests[side.name] != digest {
			return fmt.Errorf("independent verify receipt does not bind %s snapshot", side.name)
		}
	}
	return nil
}

func receiptPhase(receipts []contract.Receipt, phase contract.Phase) (contract.Receipt, bool) {
	for _, r := range receipts {
		if r.Phase == phase && r.State == contract.Succeeded {
			return r, true
		}
	}
	return contract.Receipt{}, false
}

// SnapshotDigest hashes the validated logical content in canonical store/key order.
func SnapshotDigest(s contract.Snapshot) (string, error) {
	indexed, err := indexSnapshot(s)
	if err != nil {
		return "", err
	}
	stores := make([]contract.LogicalStore, 0, len(indexed))
	for name, entries := range indexed {
		store := contract.LogicalStore{Name: name}
		for key, value := range entries {
			canonical := clone(value)
			if canonical == nil {
				canonical = []byte{}
			}
			store.Entries = append(store.Entries, contract.Entry{Key: []byte(key), Value: canonical})
		}
		sort.Slice(store.Entries, func(i, j int) bool { return bytes.Compare(store.Entries[i].Key, store.Entries[j].Key) < 0 })
		stores = append(stores, store)
	}
	sort.Slice(stores, func(i, j int) bool { return stores[i].Name < stores[j].Name })
	digest, err := contract.Digest(contract.Snapshot{Stores: stores})
	if err != nil {
		return "", err
	}
	return digest, nil
}

func validateReceipts(binding contract.RunBinding, digest string, receipts []contract.Receipt) error {
	if len(receipts) == 0 {
		return errors.New("required receipts missing")
	}
	seen := map[contract.Phase]bool{}
	var previousSequence uint64
	phaseOrder := map[contract.Phase]int{contract.Capture: 1, contract.Stage: 2, contract.Run: 3, contract.Verify: 4}
	previousPhaseOrder := 0
	previousReceiptDigest := ""
	for i := 0; i < len(receipts); {
		intent := receipts[i]
		if contract.ValidateReceipt(intent, binding) != nil || intent.BindingDigest != digest {
			return errors.New("receipt run or binding mismatch")
		}
		if intent.State != contract.Running {
			return errors.New("receipt intent is not running")
		}
		if i == 0 && intent.Predecessor != "" || i > 0 && intent.Predecessor != previousReceiptDigest {
			return errors.New("receipt predecessor chain is invalid")
		}
		if intent.Sequence != previousSequence+1 {
			return errors.New("receipt sequence is not increasing")
		}
		if i+1 >= len(receipts) {
			return errors.New("unresolved receipt intent")
		}
		result := receipts[i+1]
		if contract.ValidateReceipt(result, binding) != nil || result.BindingDigest != digest {
			return errors.New("receipt run or binding mismatch")
		}
		if result.State != contract.Succeeded || result.Phase != intent.Phase || result.Operation != intent.Operation {
			return errors.New("receipt intent has no matching successful result")
		}
		if result.Sequence != intent.Sequence+1 || result.Predecessor != digestReceipt(intent) {
			return errors.New("receipt predecessor chain is invalid")
		}
		if result.Phase == contract.Capture || result.Phase == contract.Stage || result.Phase == contract.Run || result.Phase == contract.Verify {
			if seen[result.Phase] {
				return errors.New("duplicate or empty phase receipt")
			}
			if len(result.EvidenceDigests) == 0 {
				return errors.New("successful receipt has no evidence digests")
			}
			order := phaseOrder[result.Phase]
			if order <= previousPhaseOrder {
				return errors.New("required receipt phase order is invalid")
			}
			previousPhaseOrder = order
			seen[result.Phase] = true
		}
		previousSequence = result.Sequence
		previousReceiptDigest = digestReceipt(result)
		if previousReceiptDigest == "" {
			return errors.New("receipt digest unavailable")
		}
		i += 2
	}
	for _, phase := range []contract.Phase{contract.Capture, contract.Stage, contract.Run, contract.Verify} {
		if !seen[phase] {
			return fmt.Errorf("required receipt missing for %s", phase)
		}
	}
	return nil
}

func digestReceipt(receipt contract.Receipt) string {
	digest, err := contract.Digest(receipt)
	if err != nil {
		return ""
	}
	return digest
}

func validateStoreInventory(stores []string) (map[string]struct{}, error) {
	if len(stores) == 0 {
		return nil, errors.New("required store inventory missing")
	}
	out := make(map[string]struct{}, len(stores))
	for _, name := range stores {
		if strings.TrimSpace(name) == "" {
			return nil, errors.New("empty required store")
		}
		if _, ok := out[name]; ok {
			return nil, errors.New("duplicate required store")
		}
		out[name] = struct{}{}
	}
	return out, nil
}

func hasRequiredStores(snapshot contract.Snapshot, required map[string]struct{}) bool {
	indexed, err := indexSnapshot(snapshot)
	if err != nil || len(indexed) != len(required) {
		return false
	}
	for name := range required {
		if _, ok := indexed[name]; !ok {
			return false
		}
	}
	return true
}

func validateAllowlist(changes []contract.Change) ([]contract.Change, error) {
	if changes == nil {
		return nil, errors.New("absent allowlist")
	}
	out := make([]contract.Change, len(changes))
	copy(out, changes)
	for i := range out {
		if out[i].Store == "" || !out[i].Before.Present && len(out[i].Before.Bytes) != 0 || !out[i].After.Present && len(out[i].After.Bytes) != 0 {
			return nil, errors.New("invalid change")
		}
	}
	sortChanges(out)
	for i := 1; i < len(out); i++ {
		if sameKey(out[i-1], out[i]) {
			return nil, errors.New("duplicate allowlist key")
		}
	}
	return out, nil
}

func sameChanges(a, b []contract.Change) bool {
	if len(a) != len(b) {
		return false
	}
	aa, err := validateAllowlist(a)
	if err != nil {
		return false
	}
	bb, err := validateAllowlist(b)
	if err != nil {
		return false
	}
	for i := range aa {
		if !equalChange(aa[i], bb[i]) {
			return false
		}
	}
	return true
}

func equalChange(a, b contract.Change) bool {
	return a.Store == b.Store && bytes.Equal(a.Key, b.Key) && equalValue(a.Before, b.Before) && equalValue(a.After, b.After)
}
func equalValue(a, b contract.Value) bool {
	return a.Present == b.Present && (!a.Present || bytes.Equal(a.Bytes, b.Bytes))
}
func sameKey(a, b contract.Change) bool { return a.Store == b.Store && bytes.Equal(a.Key, b.Key) }
func clone(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append([]byte{}, b...)
}
func sortChanges(c []contract.Change) {
	sort.Slice(c, func(i, j int) bool {
		if c[i].Store != c[j].Store {
			return c[i].Store < c[j].Store
		}
		return bytes.Compare(c[i].Key, c[j].Key) < 0
	})
}

// Redact removes path-like and secret-like content before report rendering.
func Redact(s string) string {
	s = secretPattern.ReplaceAllString(s, "$1$2[redacted]")
	s = pathPattern.ReplaceAllString(s, "$1[redacted-path]")
	return strings.Join(strings.Fields(s), " ")
}

// Render creates deterministic redacted JSON and Markdown reports.
func Render(result Result) (Report, error) {
	if result.SchemaVersion != Version || result.BindingDigest != "" && !contract.IsDigest(result.BindingDigest) || result.ProducerEvidenceDigest != "" && !contract.IsDigest(result.ProducerEvidenceDigest) {
		return Report{}, errors.New("invalid report identity")
	}
	if result.Verdict != contract.Pass && result.Verdict != contract.Fail && result.Verdict != contract.VerdictBlocked && result.Verdict != contract.Inconclusive {
		return Report{}, errors.New("invalid verdict")
	}
	if result.Qualification != "pending" && result.Qualification != "not_run" && result.Qualification != "evidence_verified" {
		return Report{}, errors.New("invalid qualification")
	}
	clean := result
	clean.Domains = append([]DomainResult(nil), result.Domains...)
	clean.Receipts = append([]contract.Receipt(nil), result.Receipts...)
	sort.Slice(clean.Domains, func(i, j int) bool { return clean.Domains[i].Domain < clean.Domains[j].Domain })
	clean.Reason = safeReason(clean.Reason)
	// Never serialize raw keys or values into a human-facing report: arbitrary
	// store data may contain secrets even when its encoding is opaque.
	type domainSummary struct {
		Domain      contract.Domain `json:"domain"`
		ChangeCount int             `json:"change_count"`
		Allowed     bool            `json:"allowlist_match"`
	}
	type receiptSummary struct {
		Phase         contract.Phase `json:"phase"`
		State         contract.State `json:"state"`
		EvidenceCount int            `json:"evidence_count"`
	}
	type reportSummary struct {
		SchemaVersion          string           `json:"schema_version"`
		BindingDigest          string           `json:"binding_digest,omitempty"`
		ProducerEvidenceDigest string           `json:"producer_evidence_digest,omitempty"`
		Verdict                contract.Verdict `json:"verdict"`
		Qualification          string           `json:"qualification"`
		Reason                 string           `json:"reason,omitempty"`
		Domains                []domainSummary  `json:"domains"`
		MigrationEqual         bool             `json:"migration_equal,omitempty"`
		Receipts               []receiptSummary `json:"receipts"`
	}
	summary := reportSummary{SchemaVersion: clean.SchemaVersion, BindingDigest: clean.BindingDigest, ProducerEvidenceDigest: clean.ProducerEvidenceDigest, Verdict: clean.Verdict, Qualification: clean.Qualification, Reason: clean.Reason, MigrationEqual: clean.MigrationEqual}
	for _, receipt := range clean.Receipts {
		if !contract.ValidPhase(receipt.Phase) || !validState(receipt.State) {
			return Report{}, errors.New("invalid receipt summary fields")
		}
		summary.Receipts = append(summary.Receipts, receiptSummary{Phase: receipt.Phase, State: receipt.State, EvidenceCount: len(receipt.EvidenceDigests)})
	}
	sort.Slice(summary.Receipts, func(i, j int) bool { return summary.Receipts[i].Phase < summary.Receipts[j].Phase })
	for _, d := range clean.Domains {
		if d.Domain != contract.Topology && d.Domain != contract.Migration && d.Domain != contract.Block {
			return Report{}, errors.New("invalid domain summary")
		}
		summary.Domains = append(summary.Domains, domainSummary{Domain: d.Domain, ChangeCount: len(d.Changes), Allowed: d.Allowed})
	}
	data, err := json.MarshalIndent(summary, "", "  ")
	if err != nil {
		return Report{}, err
	}
	var md strings.Builder
	fmt.Fprintf(&md, "# Recovery rehearsal evidence\n\n- Schema: `%s`\n- Verdict: **%s**\n- Qualification: `%s`\n", clean.SchemaVersion, clean.Verdict, clean.Qualification)
	if clean.ProducerEvidenceDigest != "" {
		fmt.Fprintf(&md, "- Producer evidence digest: `%s`\n", clean.ProducerEvidenceDigest)
	}
	if clean.Reason != "" {
		fmt.Fprintf(&md, "- Reason: %s\n", clean.Reason)
	}
	for _, d := range clean.Domains {
		fmt.Fprintf(&md, "\n## %s\n\nChanges: %d; allowlist match: %t.\n", d.Domain, len(d.Changes), d.Allowed)
	}
	return Report{JSON: data, Markdown: []byte(md.String())}, nil
}

func validState(state contract.State) bool {
	switch state {
	case contract.Planned, contract.Running, contract.Succeeded, contract.Failed, contract.Blocked, contract.Unknown:
		return true
	}
	return false
}

func safeReason(reason string) string {
	if reason == "" {
		return ""
	}
	known := map[string]bool{
		"preview only; runtime qualification not run": true, "schema or run binding mismatch": true, "binding digest unavailable": true,
		"required store inventory is invalid": true, "all three domains are required": true, "unknown evidence domain": true, "duplicate evidence domain": true,
		"consensus height unavailable": true, "independent consensus height unavailable": true,
		"domain snapshot omits a required store": true, "snapshot incomplete or invalid": true, "invalid allowlist": true,
		"observed changes do not exactly match domain allowlist": true, "required evidence domain missing": true,
		"independent migration comparison evidence missing": true, "independent run binding is invalid or not distinct": true,
		"migration pre-state incomplete": true, "independent run snapshot omits a required store": true,
		"independent migration pre-states differ": true, "independent migration snapshots are incomplete": true,
		"independent migration deltas differ": true, "independent binding digest unavailable": true,
		"independent run receipts are incomplete or invalid": true, "snapshot digest unavailable": true,
		"verify receipt does not bind topology.before snapshot": true, "verify receipt does not bind topology.after snapshot": true,
		"verify receipt does not bind migration.before snapshot": true, "verify receipt does not bind migration.after snapshot": true,
		"verify receipt does not bind block.before snapshot": true, "verify receipt does not bind block.after snapshot": true,
		"independent snapshot digest unavailable": true, "independent verify receipt does not bind migration.before snapshot": true,
		"independent verify receipt does not bind migration.after snapshot": true, "required receipts missing": true,
		"receipt run or binding mismatch": true, "required phase receipt not succeeded": true, "successful receipt has no evidence digests": true,
		"duplicate or empty phase receipt": true, "receipt sequence is not increasing": true, "receipt predecessor chain is invalid": true,
		"receipt intent is not running": true, "unresolved receipt intent": true, "receipt intent has no matching successful result": true,
		"required receipt phase order is invalid": true, "receipt digest unavailable": true, "verify receipt missing": true,
		"independent verify receipt missing": true,
	}
	for _, phase := range []contract.Phase{contract.Capture, contract.Stage, contract.Run, contract.Verify} {
		if reason == "required receipt missing for "+string(phase) {
			return "A required phase receipt is missing."
		}
	}
	if known[reason] {
		return reason
	}
	return "Evaluation details omitted from this report."
}
