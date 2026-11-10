// Package catalog verifies the signed, scenario-specific recovery inputs used
// by the offline rehearsal dispatcher. It does not establish production
// qualification; catalog roots and artifact identities must be supplied by
// the caller from an independently reviewed trust bundle.
package catalog

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

const (
	CatalogKind   = "catalog"
	ArtifactKind  = "recovery_artifact"
	CatalogScope  = "epoch-length-live-update"
	ArtifactScope = "stage"
)

type Scenario struct {
	ID                 string              `json:"id"`
	Description        string              `json:"description"`
	BuildDigests       map[string]string   `json:"build_digests"`
	RuntimeDigests     map[string]string   `json:"runtime_digests"`
	Backends           []string            `json:"backends"`
	Layouts            []string            `json:"layouts"`
	Files              []FileRule          `json:"files"`
	BackendVersions    map[string][]string `json:"backend_versions"`
	MigrationKeys      []MigrationKey      `json:"migration_keys"`
	RequiredStores     *[]string           `json:"required_stores,omitempty"`
	TopologyPolicy     *DomainPolicy       `json:"topology_policy,omitempty"`
	BlockPolicy        *DomainPolicy       `json:"block_policy,omitempty"`
	Heights            contract.Heights    `json:"heights"`
	FirstRepairedBlock int64               `json:"first_repaired_block"`
}

type FileRule struct {
	Path      string `json:"path"`
	Required  bool   `json:"required"`
	Kind      string `json:"kind"`
	Component string `json:"component"`
}
type MigrationKey struct {
	Store         string `json:"store"`
	KeyHex        string `json:"key_hex"`
	BeforePresent bool   `json:"before_present"`
	BeforeSHA256  string `json:"before_sha256"`
	AfterPresent  bool   `json:"after_present"`
	AfterSHA256   string `json:"after_sha256"`
}

// PolicyChange contains only identity and value hashes, never raw store
// values. It is the common hash/presence representation for all domains.
type PolicyChange struct {
	Store         string `json:"store"`
	KeyHex        string `json:"key_hex"`
	BeforePresent bool   `json:"before_present"`
	BeforeSHA256  string `json:"before_sha256"`
	AfterPresent  bool   `json:"after_present"`
	AfterSHA256   string `json:"after_sha256"`
}
type DomainPolicy struct {
	Changes []PolicyChange `json:"changes"`
}
type Catalog struct {
	Metadata      contract.SignedMetadata `json:"-"`
	Scenarios     []Scenario              `json:"scenarios"`
	bindingDigest string
	contentDigest string
	document      contract.SignedDocument
}

type ArtifactFile struct {
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
	Component string `json:"component"`
}
type RecoveryArtifact struct {
	Metadata           contract.SignedMetadata `json:"-"`
	ScenarioID         string                  `json:"scenario_id"`
	BuildDigests       map[string]string       `json:"build_digests"`
	RuntimeDigests     map[string]string       `json:"runtime_digests"`
	Backend            string                  `json:"backend"`
	BackendVersion     string                  `json:"backend_version"`
	Layout             string                  `json:"layout"`
	Files              []ArtifactFile          `json:"files"`
	MigrationKeys      []MigrationKey          `json:"migration_keys"`
	RequiredStores     *[]string               `json:"required_stores,omitempty"`
	TopologyPolicy     *DomainPolicy           `json:"topology_policy,omitempty"`
	BlockPolicy        *DomainPolicy           `json:"block_policy,omitempty"`
	Heights            contract.Heights        `json:"heights"`
	FirstRepairedBlock int64                   `json:"first_repaired_block"`
}

type Policy struct {
	Verification input.VerificationPolicy
	Scope        string
}

// DecodeEnvelope uses the shared duplicate-key, unknown-field and trailing
// JSON rejection rules while retaining the original payload bytes.
func DecodeEnvelope(raw []byte) (contract.SignedDocument, error) {
	var envelope map[string]json.RawMessage
	if err := contract.DecodeStrict(raw, &envelope); err != nil {
		return contract.SignedDocument{}, err
	}
	if len(envelope) != 2 || envelope["payload"] == nil || envelope["signature_hex"] == nil {
		return contract.SignedDocument{}, fmt.Errorf("signed envelope must contain payload and signature_hex only")
	}
	var doc contract.SignedDocument
	if err := contract.DecodeStrict(raw, &doc); err != nil {
		return doc, err
	}
	if len(doc.Payload) == 0 || doc.SignatureHex == "" {
		return doc, fmt.Errorf("signed envelope is incomplete")
	}
	return doc, nil
}

func VerifyCatalog(doc contract.SignedDocument, policy Policy) (Catalog, error) {
	var out Catalog
	if policy.Scope != "" && policy.Scope != CatalogScope {
		return out, fmt.Errorf("catalog scope is fixed")
	}
	if err := verify(doc, policy.Verification, CatalogKind, CatalogScope, "catalog", func(payload []byte) error {
		var wire struct {
			contract.SignedMetadata
			Scenarios []Scenario `json:"scenarios"`
		}
		if err := exactShape(payload, catalogShape()); err != nil {
			return err
		}
		if err := contract.DecodeStrict(payload, &wire); err != nil {
			return err
		}
		for _, scenario := range wire.Scenarios {
			if err := validateScenario(scenario); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return out, err
	}
	var wire struct {
		contract.SignedMetadata
		Scenarios []Scenario `json:"scenarios"`
	}
	if err := contract.DecodeStrict(doc.Payload, &wire); err != nil {
		return out, err
	}
	if len(wire.Scenarios) == 0 {
		return out, fmt.Errorf("catalog has no scenarios")
	}
	seen := map[string]bool{}
	matched := false
	for _, scenario := range wire.Scenarios {
		if err := validateScenario(scenario); err != nil {
			return out, err
		}
		if seen[scenario.ID] {
			return out, fmt.Errorf("duplicate scenario %q", scenario.ID)
		}
		seen[scenario.ID] = true
		if scenario.ID == policy.Verification.Binding.Scenario {
			matched = true
			if scenario.FirstRepairedBlock != policy.Verification.Binding.Heights.FirstRepaired || !sameHeights(scenario.Heights, policy.Verification.Binding.Heights) || !sameStrings(scenario.RuntimeDigests, policy.Verification.Binding.RuntimeIdentities) {
				return out, fmt.Errorf("catalog scenario runtime or heights differ from run binding")
			}
		}
	}
	if !matched {
		return out, fmt.Errorf("catalog does not contain the bound scenario")
	}
	bindingDigest, err := contract.InputBindingDigest(policy.Verification.Binding)
	if err != nil {
		return out, err
	}
	contentDigest, err := contract.Digest(wire.Scenarios)
	if err != nil {
		return out, err
	}
	out.Metadata, out.Scenarios, out.bindingDigest, out.contentDigest, out.document = wire.SignedMetadata, wire.Scenarios, bindingDigest, contentDigest, doc
	return out, nil
}

func VerifyArtifact(doc contract.SignedDocument, policy Policy, approvedCatalog Catalog) (RecoveryArtifact, error) {
	var out RecoveryArtifact
	if policy.Scope != "" && policy.Scope != ArtifactScope {
		return out, fmt.Errorf("artifact scope is fixed")
	}
	if err := verify(doc, policy.Verification, ArtifactKind, ArtifactScope, "core", func(payload []byte) error {
		var wire struct {
			contract.SignedMetadata
			RecoveryArtifact
		}
		if err := exactShape(payload, artifactShape()); err != nil {
			return err
		}
		return contract.DecodeStrict(payload, &wire)
	}); err != nil {
		return out, err
	}
	boundDigest, err := contract.InputBindingDigest(policy.Verification.Binding)
	if err != nil || approvedCatalog.bindingDigest != boundDigest || approvedCatalog.Metadata.Kind != CatalogKind || approvedCatalog.Metadata.Scope != CatalogScope || approvedCatalog.Metadata.BindingDigest != boundDigest || approvedCatalog.Metadata.RunID != policy.Verification.Binding.RunID || approvedCatalog.Metadata.ChainID != policy.Verification.Binding.ChainID || approvedCatalog.Metadata.GenesisSHA256 != policy.Verification.Binding.GenesisSHA256 {
		return out, fmt.Errorf("catalog is not verified for this run binding")
	}
	catalogPolicy := policy.Verification
	catalogPolicy.Kind, catalogPolicy.Scope, catalogPolicy.Role = "", "", ""
	if err := verify(approvedCatalog.document, catalogPolicy, CatalogKind, CatalogScope, "catalog", func(payload []byte) error {
		if err := exactShape(payload, catalogShape()); err != nil {
			return err
		}
		var wire struct {
			contract.SignedMetadata
			Scenarios []Scenario `json:"scenarios"`
		}
		return contract.DecodeStrict(payload, &wire)
	}); err != nil {
		return out, fmt.Errorf("catalog revalidation failed: %w", err)
	}
	contentDigest, err := contract.Digest(approvedCatalog.Scenarios)
	if err != nil || approvedCatalog.contentDigest == "" || contentDigest != approvedCatalog.contentDigest {
		return out, fmt.Errorf("verified catalog was modified")
	}
	var approved *Scenario
	for i := range approvedCatalog.Scenarios {
		if approvedCatalog.Scenarios[i].ID == policy.Verification.Binding.Scenario {
			approved = &approvedCatalog.Scenarios[i]
			break
		}
	}
	if approved == nil {
		return out, fmt.Errorf("catalog does not contain the bound scenario")
	}
	var wire struct {
		contract.SignedMetadata
		RecoveryArtifact
	}
	if err := contract.DecodeStrict(doc.Payload, &wire); err != nil {
		return out, err
	}
	a := wire.RecoveryArtifact
	if a.ScenarioID != approved.ID || a.FirstRepairedBlock != approved.FirstRepairedBlock || a.FirstRepairedBlock != policy.Verification.Binding.Heights.FirstRepaired || !sameHeights(a.Heights, approved.Heights) || !sameHeights(a.Heights, policy.Verification.Binding.Heights) || policy.Verification.Binding.Heights.Consensus == nil ||
		!sameStrings(a.BuildDigests, approved.BuildDigests) || !sameStrings(a.RuntimeDigests, approved.RuntimeDigests) || !sameStrings(a.RuntimeDigests, policy.Verification.Binding.RuntimeIdentities) ||
		!contains(approved.Backends, a.Backend) || !contains(approved.Layouts, a.Layout) || !contains(approved.BackendVersions[a.Backend], a.BackendVersion) ||
		!sameMigration(a.MigrationKeys, approved.MigrationKeys) || !sameRequiredStores(a.RequiredStores, approved.RequiredStores) ||
		!sameDomainPolicy(a.TopologyPolicy, approved.TopologyPolicy) || !sameDomainPolicy(a.BlockPolicy, approved.BlockPolicy) {
		return out, fmt.Errorf("artifact identity or allowlist differs from signed catalog")
	}
	if err := validateArtifactFiles(a.Files, approved.Files); err != nil {
		return out, err
	}
	a.Metadata = wire.SignedMetadata
	return a, nil
}

func verify(doc contract.SignedDocument, p input.VerificationPolicy, kind, scope, role string, validate func([]byte) error) error {
	if p.Kind != "" && p.Kind != kind || p.Scope != "" && p.Scope != scope || p.Role != "" && p.Role != role {
		return fmt.Errorf("verification policy kind, scope, or role mismatch")
	}
	p.Kind, p.Scope, p.Role = kind, scope, role
	_, err := input.VerifyTypedDocument(doc, p, validate)
	return err
}

type shape struct {
	fields   map[string]*shape
	element  *shape
	dynamic  bool
	optional bool
	nonnull  bool
}

func object(fields map[string]*shape) *shape { return &shape{fields: fields} }
func list(element *shape) *shape             { return &shape{element: element} }
func scalar() *shape                         { return &shape{} }
func optionalShape(child *shape) *shape      { child.optional = true; child.nonnull = true; return child }
func stringMap() *shape                      { return &shape{dynamic: true} }
func versionMap() *shape                     { return &shape{dynamic: true, element: list(scalar())} }
func metadataShape() map[string]*shape {
	return map[string]*shape{"schema_version": scalar(), "kind": scalar(), "scope": scalar(), "key_id": scalar(), "run_id": scalar(), "binding_digest": scalar(), "chain_id": scalar(), "genesis_sha256": scalar(), "issued_at": scalar(), "expires_at": scalar()}
}
func migrationShape() *shape {
	return object(map[string]*shape{"store": scalar(), "key_hex": scalar(), "before_present": scalar(), "before_sha256": scalar(), "after_present": scalar(), "after_sha256": scalar()})
}
func heightsShape() *shape {
	return object(map[string]*shape{"blockstore": scalar(), "app": scalar(), "consensus": scalar(), "first_repaired": scalar()})
}
func policyChangeShape() *shape {
	return object(map[string]*shape{"store": scalar(), "key_hex": scalar(), "before_present": scalar(), "before_sha256": scalar(), "after_present": scalar(), "after_sha256": scalar()})
}
func domainPolicyShape() *shape {
	return object(map[string]*shape{"changes": list(policyChangeShape())})
}
func catalogShape() *shape {
	f := metadataShape()
	f["scenarios"] = list(object(map[string]*shape{"id": scalar(), "description": scalar(), "build_digests": stringMap(), "runtime_digests": stringMap(), "backends": list(scalar()), "layouts": list(scalar()), "backend_versions": versionMap(), "files": list(object(map[string]*shape{"path": scalar(), "required": scalar(), "kind": scalar(), "component": scalar()})), "migration_keys": list(migrationShape()), "required_stores": optionalShape(list(scalar())), "topology_policy": optionalShape(domainPolicyShape()), "block_policy": optionalShape(domainPolicyShape()), "heights": heightsShape(), "first_repaired_block": scalar()}))
	return object(f)
}
func artifactShape() *shape {
	f := metadataShape()
	for k, v := range map[string]*shape{"scenario_id": scalar(), "build_digests": stringMap(), "runtime_digests": stringMap(), "backend": scalar(), "backend_version": scalar(), "layout": scalar(), "files": list(object(map[string]*shape{"path": scalar(), "sha256": scalar(), "size": scalar(), "component": scalar()})), "migration_keys": list(migrationShape()), "required_stores": optionalShape(list(scalar())), "topology_policy": optionalShape(domainPolicyShape()), "block_policy": optionalShape(domainPolicyShape()), "heights": heightsShape(), "first_repaired_block": scalar()} {
		f[k] = v
	}
	return object(f)
}
func exactShape(raw []byte, expected *shape) error {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	return checkShape(value, expected)
}
func checkShape(value any, expected *shape) error {
	if expected == nil {
		return nil
	}
	if expected.fields != nil {
		fields, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("signed payload object has wrong type")
		}
		required := 0
		for _, child := range expected.fields {
			if !child.optional {
				required++
			}
		}
		if len(fields) < required || len(fields) > len(expected.fields) {
			return fmt.Errorf("signed payload object has missing or unsupported fields")
		}
		for name, child := range expected.fields {
			got, ok := fields[name]
			if !ok {
				if child.optional {
					continue
				}
				return fmt.Errorf("signed payload is missing exact field %q", name)
			}
			if err := checkShape(got, child); err != nil {
				return fmt.Errorf("field %s: %w", name, err)
			}
		}
		return nil
	}
	if expected.dynamic {
		fields, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("signed payload map has wrong type")
		}
		for key, item := range fields {
			if key == "" {
				return fmt.Errorf("signed payload map has empty key")
			}
			if expected.element != nil {
				if err := checkShape(item, expected.element); err != nil {
					return err
				}
			} else if _, ok := item.(string); !ok {
				return fmt.Errorf("signed payload map value has wrong type")
			}
		}
		return nil
	}
	if expected.element != nil {
		values, ok := value.([]any)
		if !ok {
			return fmt.Errorf("signed payload array has wrong type")
		}
		for i, item := range values {
			if err := checkShape(item, expected.element); err != nil {
				return fmt.Errorf("array item %d: %w", i, err)
			}
		}
		return nil
	}
	if expected.nonnull && value == nil {
		return fmt.Errorf("signed payload field must not be null")
	}
	return nil
}

func validateScenario(s Scenario) error {
	if s.ID == "" || s.Description == "" || s.FirstRepairedBlock <= 0 || s.Heights.FirstRepaired != s.FirstRepairedBlock || s.Heights.Blockstore < 0 || s.Heights.App < 0 || s.Heights.Consensus != nil && *s.Heights.Consensus < 0 || len(s.BuildDigests) == 0 || len(s.RuntimeDigests) == 0 || len(s.Backends) == 0 || len(s.Layouts) == 0 || len(s.Files) == 0 || len(s.BackendVersions) != len(s.Backends) {
		return fmt.Errorf("catalog scenario is incomplete")
	}
	for _, d := range append(values(s.BuildDigests), values(s.RuntimeDigests)...) {
		if !contract.IsDigest(d) {
			return fmt.Errorf("catalog contains invalid build/runtime digest")
		}
	}
	if err := uniqueNonempty(s.Backends); err != nil {
		return err
	}
	if err := uniqueNonempty(s.Layouts); err != nil {
		return err
	}
	for _, backend := range s.Backends {
		versions, ok := s.BackendVersions[backend]
		if !ok || uniqueNonempty(versions) != nil {
			return fmt.Errorf("backend version allowlist is incomplete")
		}
	}
	for backend := range s.BackendVersions {
		if !contains(s.Backends, backend) {
			return fmt.Errorf("backend version allowlist names an unapproved backend")
		}
	}
	if err := validateFileRules(s.Files); err != nil {
		return err
	}
	if err := validateMigration(s.MigrationKeys); err != nil {
		return err
	}
	if err := validateRequiredStores(s.RequiredStores); err != nil {
		return err
	}
	if err := validateDomainPolicy(s.TopologyPolicy); err != nil {
		return err
	}
	return validateDomainPolicy(s.BlockPolicy)
}
func sameHeights(a, b contract.Heights) bool {
	if a.Blockstore != b.Blockstore || a.App != b.App || a.FirstRepaired != b.FirstRepaired {
		return false
	}
	if a.Consensus == nil || b.Consensus == nil {
		return a.Consensus == nil && b.Consensus == nil
	}
	return *a.Consensus == *b.Consensus
}
func validateFileRules(files []FileRule) error {
	seen := map[string]bool{}
	for _, f := range files {
		if !safePath(f.Path) || seen[f.Path] || !f.Required || f.Kind != "file" || strings.TrimSpace(f.Component) == "" {
			return fmt.Errorf("invalid or duplicate artifact file rule")
		}
		seen[f.Path] = true
	}
	return nil
}
func validateArtifactFiles(files []ArtifactFile, rules []FileRule) error {
	if len(files) != len(rules) {
		return fmt.Errorf("artifact file inventory differs from catalog")
	}
	allowed := map[string]bool{}
	for _, r := range rules {
		allowed[r.Path] = true
	}
	seen := map[string]bool{}
	for _, f := range files {
		if !allowed[f.Path] || seen[f.Path] || !contract.IsDigest(f.SHA256) || f.Size < 0 || f.Component != allowedComponent(rules, f.Path) {
			return fmt.Errorf("artifact contains unapproved or invalid file")
		}
		seen[f.Path] = true
	}
	return nil
}
func allowedComponent(rules []FileRule, name string) string {
	for _, rule := range rules {
		if rule.Path == name {
			return rule.Component
		}
	}
	return ""
}
func validateMigration(keys []MigrationKey) error {
	seen := map[string]bool{}
	for _, k := range keys {
		identity := k.Store + "/" + k.KeyHex
		beforeValid := k.BeforePresent && contract.IsDigest(k.BeforeSHA256) || !k.BeforePresent && k.BeforeSHA256 == ""
		afterValid := k.AfterPresent && contract.IsDigest(k.AfterSHA256) || !k.AfterPresent && k.AfterSHA256 == ""
		if k.Store == "" || !isHex(k.KeyHex) || !beforeValid || !afterValid || k.BeforePresent == k.AfterPresent && k.BeforeSHA256 == k.AfterSHA256 || seen[identity] {
			return fmt.Errorf("invalid or duplicate migration allowlist identity")
		}
		seen[identity] = true
	}
	return nil
}
func validateRequiredStores(stores *[]string) error {
	if stores == nil {
		return nil
	}
	if len(*stores) == 0 || uniqueNonempty(*stores) != nil {
		return fmt.Errorf("required store inventory is empty or duplicated")
	}
	return nil
}
func validateDomainPolicy(policy *DomainPolicy) error {
	if policy == nil {
		return nil
	}
	if policy.Changes == nil {
		return fmt.Errorf("domain policy changes must be explicitly present")
	}
	seen := map[string]bool{}
	for _, change := range policy.Changes {
		identity := change.Store + "/" + change.KeyHex
		beforeValid := change.BeforePresent && contract.IsDigest(change.BeforeSHA256) || !change.BeforePresent && change.BeforeSHA256 == ""
		afterValid := change.AfterPresent && contract.IsDigest(change.AfterSHA256) || !change.AfterPresent && change.AfterSHA256 == ""
		if change.Store == "" || !isHex(change.KeyHex) || !beforeValid || !afterValid || change.BeforePresent == change.AfterPresent && change.BeforeSHA256 == change.AfterSHA256 || seen[identity] {
			return fmt.Errorf("invalid or duplicate domain policy identity")
		}
		seen[identity] = true
	}
	return nil
}
func sameMigration(a, b []MigrationKey) bool {
	if validateMigration(a) != nil || validateMigration(b) != nil || len(a) != len(b) {
		return false
	}
	m := map[string]MigrationKey{}
	for _, v := range a {
		m[v.Store+"/"+v.KeyHex] = v
	}
	for _, v := range b {
		if m[v.Store+"/"+v.KeyHex] != v {
			return false
		}
	}
	return true
}
func sameRequiredStores(a, b *[]string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if len(*a) != len(*b) {
		return false
	}
	values := map[string]bool{}
	for _, name := range *a {
		values[name] = true
	}
	for _, name := range *b {
		if !values[name] {
			return false
		}
	}
	if len(values) != len(*a) {
		return false
	}
	return true
}
func sameDomainPolicy(a, b *DomainPolicy) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if validateDomainPolicy(a) != nil || validateDomainPolicy(b) != nil || len(a.Changes) != len(b.Changes) {
		return false
	}
	left := map[string]PolicyChange{}
	for _, change := range a.Changes {
		left[change.Store+"/"+change.KeyHex] = change
	}
	for _, change := range b.Changes {
		if left[change.Store+"/"+change.KeyHex] != change {
			return false
		}
	}
	return true
}
func sameStrings(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v || !contract.IsDigest(v) {
			return false
		}
	}
	return true
}
func values(m map[string]string) []string {
	r := make([]string, 0, len(m))
	for _, v := range m {
		r = append(r, v)
	}
	return r
}
func contains(a []string, s string) bool {
	for _, v := range a {
		if v == s {
			return true
		}
	}
	return false
}
func uniqueNonempty(a []string) error {
	m := map[string]bool{}
	for _, v := range a {
		if strings.TrimSpace(v) == "" || m[v] {
			return fmt.Errorf("empty or duplicate catalog value")
		}
		m[v] = true
	}
	return nil
}
func safePath(p string) bool {
	return p != "" && !strings.HasPrefix(p, "/") && !strings.Contains(p, "\\") && p != "." && path.Clean(p) == p && !strings.HasPrefix(p, "../")
}
func isHex(s string) bool {
	if s == "" || len(s)%2 != 0 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && s == strings.ToLower(s)
}
