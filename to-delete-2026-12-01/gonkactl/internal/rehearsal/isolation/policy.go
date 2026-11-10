// Package isolation defines fail-closed policies and adapters for local
// recovery rehearsal resources. Runtime use still requires separate, genuine
// isolation probes; command and configuration checks alone are not proof.
package isolation

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

var ErrUnsafeSpec = errors.New("unsafe rehearsal runtime specification")
var ErrForeignResource = errors.New("resource is not owned exclusively by this rehearsal")

type Mount struct {
	PathKey  string
	Target   string
	ReadOnly bool
}
type Port struct{ Container, Host string }
type BinaryRole string

const (
	BinaryRecovery BinaryRole = "recovery"
	BinaryOriginal BinaryRole = "original"
)

type ContainerSpec struct {
	Name                             string
	Image                            string // must be an immutable sha256 digest reference
	Argv                             []string
	Privileged, HostNetwork, HostPID bool
	Mounts                           []Mount
	Ports                            []Port
	Labels                           map[string]string
	Network                          *PinnedNetwork // nil is the fail-closed network-none default
	Entrypoint                       []string
	Environment                      map[string]string
	DNSAliases                       []string
	ForkTarget                       string     // empty is /data; only /root/.inference is an alternate
	SelectedBinaryRole               BinaryRole // paired with the immutable binary path and digest
}

var safeName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$`)
var safeImageName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._/:+-]*$`)
var safeDNSAlias = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

// ValidateBinding permits only exact paths from the immutable binding. Source,
// control and evidence are readonly; only named fork paths may be writable.
func (s ContainerSpec) ValidateBinding(binding contract.RunBinding) error {
	if err := contract.ValidateBinding(binding); err != nil {
		return fmt.Errorf("invalid immutable run binding: %w", err)
	}
	if !validRolePaths(binding.Paths) {
		return ErrUnsafeSpec
	}
	if binding.RunID == "" || binding.OwnershipMarker == "" || !safeName.MatchString(s.Name) || len(s.Argv) == 0 || !validImageDigest(s.Image) {
		return ErrUnsafeSpec
	}
	for _, arg := range s.Argv {
		if arg == "" || strings.ContainsAny(arg, "\x00\n\r") {
			return ErrUnsafeSpec
		}
	}
	if s.Privileged || s.HostNetwork || s.HostPID {
		return ErrUnsafeSpec
	}
	if s.Network != nil {
		if !validNetworkPin(*s.Network, binding) || len(s.Ports) != 0 {
			return ErrUnsafeSpec
		}
	}
	if err := validateRecoveryFields(s, binding); err != nil {
		return err
	}
	if len(s.Entrypoint) > 0 {
		if err := boundRecoveryFilesMatch(binding, s.SelectedBinaryRole); err != nil {
			return err
		}
	}
	if s.ForkTarget != "" && (s.ForkTarget != "/root/.inference" || len(s.Entrypoint) == 0) {
		return ErrUnsafeSpec
	}
	if len(s.Entrypoint) > 0 {
		hasBinary := false
		for _, m := range s.Mounts {
			if m.PathKey == selectedBinaryPathKey(s.SelectedBinaryRole) && m.Target == expectedTarget(m.PathKey) {
				hasBinary = true
			}
			if (m.PathKey == "recovery-binary" || m.PathKey == "original-binary") && !m.ReadOnly {
				return ErrUnsafeSpec
			}
		}
		if !hasBinary {
			return ErrUnsafeSpec
		}
	}
	if len(s.DNSAliases) > 0 && s.Network == nil {
		return ErrUnsafeSpec
	}
	aliases := map[string]bool{}
	for _, alias := range s.DNSAliases {
		if !safeDNSAlias.MatchString(alias) || aliases[alias] {
			return ErrUnsafeSpec
		}
		aliases[alias] = true
	}
	for _, m := range s.Mounts {
		source, ok := binding.Paths[m.PathKey]
		allowedKey := m.PathKey == "source" || m.PathKey == "control" || m.PathKey == "evidence" || m.PathKey == "fork-a" || m.PathKey == "fork-b" || m.PathKey == "recovery-binary" || m.PathKey == "original-binary"
		expected := expectedTarget(m.PathKey)
		if (m.PathKey == "fork-a" || m.PathKey == "fork-b") && s.ForkTarget != "" {
			expected = s.ForkTarget
		}
		if !ok || !allowedKey || !safeAbsolutePath(source) || expected != m.Target || !safeContainerTarget(m.Target) || strings.ContainsAny(source+m.Target, ",\n\r") {
			return ErrUnsafeSpec
		}
		if (m.PathKey == "fork-a" || m.PathKey == "fork-b") == m.ReadOnly {
			return ErrUnsafeSpec
		}
		if m.PathKey != "fork-a" && m.PathKey != "fork-b" && !m.ReadOnly {
			return ErrUnsafeSpec
		}
	}
	if !validMountSet(s.Mounts) {
		return ErrUnsafeSpec
	}
	for _, p := range s.Ports {
		if !validLoopbackPort(p.Host) || !validPort(p.Container) {
			return ErrUnsafeSpec
		}
	}
	if !validPortSet(s.Ports) {
		return ErrUnsafeSpec
	}
	digest, err := contract.Digest(binding)
	if err != nil || s.Labels["gonka.rehearsal.run"] != binding.RunID || s.Labels["gonka.rehearsal.owner"] != binding.OwnershipMarker || s.Labels["gonka.rehearsal.binding"] != digest {
		return ErrUnsafeSpec
	}
	if len(s.Labels) != 3 {
		return ErrUnsafeSpec
	}
	for k, v := range s.Labels {
		if strings.ContainsAny(k+v, ",\n\r\x00") {
			return ErrUnsafeSpec
		}
	}
	return nil
}

// Command is an argv vector by design; no shell interpolation is performed.
type Command struct {
	operation  Operation
	executable string
	args       []string
	seal       string
}

func (c Command) Operation() Operation { return c.operation }
func (c Command) Executable() string   { return c.executable }
func (c Command) Args() []string       { return append([]string(nil), c.args...) }

func (s ContainerSpec) createCommand(runtime string, binding contract.RunBinding) (Command, error) {
	if err := s.ValidateBinding(binding); err != nil {
		return Command{}, err
	}
	if runtime == "" {
		return Command{}, fmt.Errorf("runtime executable is required")
	}
	network := "none"
	if s.Network != nil {
		network = s.Network.Name
	}
	args := []string{"create", "--name", s.Name, "--network", network}
	for _, key := range sortedKeys(s.Labels) {
		args = append(args, "--label", key+"="+s.Labels[key])
	}
	if len(s.Entrypoint) > 0 {
		args = append(args, "--entrypoint", s.Entrypoint[0])
	}
	for _, key := range sortedKeys(s.Environment) {
		args = append(args, "--env", key+"="+s.Environment[key])
	}
	for _, alias := range s.DNSAliases {
		args = append(args, "--network-alias", alias)
	}
	for _, m := range s.Mounts {
		mode := "readonly"
		if !m.ReadOnly {
			mode = "rw"
		}
		args = append(args, "--mount", "type=bind,src="+bindingPath(binding, m.PathKey)+",dst="+m.Target+","+mode)
	}
	for _, p := range s.Ports {
		args = append(args, "--publish", p.Host+":"+p.Container)
	}
	args = append(args, s.Image)
	if len(s.Entrypoint) > 1 {
		args = append(args, s.Entrypoint[1:]...)
	}
	args = append(args, s.Argv...)
	return newCommand(OperationCreateContainer, runtime, args), nil
}

type Resource struct {
	ID            string
	Labels        map[string]string
	Consumers     []string
	Running       bool
	StateStatus   string
	ExitCode      int
	ExitCodeKnown bool
}

func ValidateCleanup(binding contract.RunBinding, allowedIDs []string, resources []Resource) error {
	if err := contract.ValidateBinding(binding); err != nil {
		return fmt.Errorf("invalid immutable run binding: %w", err)
	}
	if binding.RunID == "" || binding.OwnershipMarker == "" || len(allowedIDs) == 0 || len(resources) != len(allowedIDs) {
		return ErrForeignResource
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return err
	}
	allowed := map[string]bool{}
	for _, id := range allowedIDs {
		if id == "" || allowed[id] {
			return ErrForeignResource
		}
		allowed[id] = true
	}
	for _, r := range resources {
		if !allowed[r.ID] || r.Labels["gonka.rehearsal.run"] != binding.RunID || r.Labels["gonka.rehearsal.owner"] != binding.OwnershipMarker || r.Labels["gonka.rehearsal.binding"] != digest {
			return fmt.Errorf("%s: %w", r.ID, ErrForeignResource)
		}
		delete(allowed, r.ID)
		if len(r.Consumers) != 0 {
			return fmt.Errorf("%s has consumers: %w", r.ID, ErrForeignResource)
		}
	}
	if len(allowed) != 0 {
		return ErrForeignResource
	}
	return nil
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func bindingPath(b contract.RunBinding, key string) string { return b.Paths[key] }
func validImageDigest(s string) bool {
	if validLocalImageID(s) {
		return true
	}
	at := strings.LastIndex(s, "@sha256:")
	if at <= 0 || strings.Count(s, "@") != 1 || !safeImageName.MatchString(s[:at]) || strings.HasPrefix(s, "-") {
		return false
	}
	h := s[at+8:]
	if len(h) != 64 {
		return false
	}
	for _, c := range h {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func validLocalImageID(s string) bool {
	if !strings.HasPrefix(s, "sha256:") || len(s) != 71 {
		return false
	}
	for _, c := range s[7:] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func expectedTarget(key string) string {
	switch key {
	case "source":
		return "/source"
	case "control":
		return "/control"
	case "fork-a", "fork-b":
		return "/data"
	case "recovery-binary", "original-binary":
		return "/root/gnklab0002/selected/inferenced"
	case "evidence":
		return "/evidence"
	default:
		return ""
	}
}
func validMountSet(mounts []Mount) bool {
	seenKey, seenTarget := map[string]bool{}, map[string]bool{}
	for _, m := range mounts {
		if seenKey[m.PathKey] || seenTarget[m.Target] {
			return false
		}
		seenKey[m.PathKey] = true
		seenTarget[m.Target] = true
	}
	base := seenKey["source"] && seenKey["control"] && seenKey["evidence"] && (seenKey["fork-a"] != seenKey["fork-b"])
	binaryCount := 0
	if seenKey["recovery-binary"] {
		binaryCount++
	}
	if seenKey["original-binary"] {
		binaryCount++
	}
	return base && !seenKey["entrypoint"] && binaryCount <= 1
}

func validateRecoveryFields(s ContainerSpec, b contract.RunBinding) error {
	if len(s.Entrypoint) == 0 && len(s.Environment) == 0 {
		if s.SelectedBinaryRole != "" {
			return ErrUnsafeSpec
		}
		for _, mount := range s.Mounts {
			if mount.PathKey == "recovery-binary" || mount.PathKey == "original-binary" {
				return ErrUnsafeSpec
			}
		}
		return nil
	}
	if len(s.Entrypoint) != 1 || s.Entrypoint[0] != "/root/gnklab0002/selected/inferenced" || len(s.Argv) != 3 || s.Argv[0] != "start" || s.Argv[1] != "--home" || s.Argv[2] != "/root/.inference" {
		return ErrUnsafeSpec
	}
	if _, legacyEntrypoint := b.Paths["entrypoint"]; legacyEntrypoint {
		return ErrUnsafeSpec
	}
	if _, legacyDigest := b.InputDigests["recovery-entrypoint"]; legacyDigest {
		return ErrUnsafeSpec
	}
	if b.Paths["recovery-binary"] == "" || b.Paths["original-binary"] == "" || !contract.IsDigest(b.InputDigests["recovery-binary"]) || !contract.IsDigest(b.InputDigests["original-binary"]) || (s.SelectedBinaryRole != "recovery" && s.SelectedBinaryRole != "original") {
		return ErrUnsafeSpec
	}
	if s.Environment["GNK_LAB_SELECTED_BINARY_ROLE"] != string(s.SelectedBinaryRole) {
		return ErrUnsafeSpec
	}
	if s.Environment["GNK_LAB_RECOVERY_BINARY_SHA256"] != b.InputDigests["recovery-binary"] || s.Environment["GNK_LAB_ORIGINAL_BINARY_SHA256"] != b.InputDigests["original-binary"] || s.Environment["GNK_LAB_RECOVERY_BARRIER_CHAIN_ID"] != b.ChainID || s.Environment["GNK_LAB_RECOVERY_BARRIER_DIR"] != "/root/.inference/gnklab0002-recovery-barrier" {
		return ErrUnsafeSpec
	}
	if len(s.Environment) != 5 {
		return ErrUnsafeSpec
	}
	for k, v := range s.Environment {
		if strings.ContainsAny(k+v, "\x00\r\n") {
			return ErrUnsafeSpec
		}
	}
	return nil
}
func cloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
func selectedBinaryPathKey(role BinaryRole) string {
	if role == BinaryRecovery || role == BinaryOriginal {
		return string(role) + "-binary"
	}
	return ""
}
func boundRecoveryFilesMatch(b contract.RunBinding, role BinaryRole) error {
	selected := selectedBinaryPathKey(role)
	if selected == "" {
		return ErrUnsafeSpec
	}
	f, err := os.Open(b.Paths[selected])
	if err != nil {
		return ErrUnsafeSpec
	}
	h := sha256.New()
	_, copyErr := io.Copy(h, f)
	closeErr := f.Close()
	if copyErr != nil || closeErr != nil || hex.EncodeToString(h.Sum(nil)) != b.InputDigests[selected] {
		return ErrUnsafeSpec
	}
	return nil
}
func validPortSet(ports []Port) bool {
	seenHost, seenContainer := map[string]bool{}, map[string]bool{}
	for _, p := range ports {
		if seenHost[p.Host] || seenContainer[p.Container] {
			return false
		}
		seenHost[p.Host] = true
		seenContainer[p.Container] = true
	}
	return true
}
func safeAbsolutePath(s string) bool {
	if !filepath.IsAbs(s) || filepath.Clean(s) != s || strings.ContainsAny(s, ",\n\r") {
		return false
	}
	for _, part := range strings.Split(filepath.Clean(s), string(filepath.Separator)) {
		if part == ".." {
			return false
		}
	}
	cur := string(filepath.Separator)
	for _, part := range strings.Split(strings.TrimPrefix(s, cur), cur) {
		if part == "" {
			continue
		}
		cur = filepath.Join(cur, part)
		info, err := os.Lstat(cur)
		if err == nil && info.Mode()&os.ModeSymlink != 0 {
			return false
		}
		if err != nil && !os.IsNotExist(err) {
			return false
		}
	}
	return true
}
func validRolePaths(paths map[string]string) bool {
	if _, legacy := paths["selected-binary"]; legacy {
		return false
	}
	keys := []string{"source", "control", "fork-a", "fork-b", "evidence"}
	resolved := make([]string, 0, len(keys))
	for _, key := range keys {
		p, ok := paths[key]
		if !ok || !safeAbsolutePath(p) {
			return false
		}
		info, err := os.Stat(p)
		if err != nil || !info.IsDir() {
			return false
		}
		resolved = append(resolved, p)
	}
	for i := range resolved {
		for j := i + 1; j < len(resolved); j++ {
			if overlaps(resolved[i], resolved[j]) {
				return false
			}
		}
	}
	recovery, hasRecovery := paths["recovery-binary"]
	original, hasOriginal := paths["original-binary"]
	if _, hasLegacyEntrypoint := paths["entrypoint"]; hasLegacyEntrypoint || hasRecovery != hasOriginal {
		return false
	}
	if hasRecovery {
		for _, p := range []string{recovery, original} {
			info, err := os.Stat(p)
			if !safeAbsolutePath(p) || err != nil || !info.Mode().IsRegular() {
				return false
			}
			for _, dir := range resolved {
				if overlaps(dir, p) {
					return false
				}
			}
		}
		if overlaps(recovery, original) {
			return false
		}
	}
	return true
}
func overlaps(a, b string) bool {
	for _, pair := range [][2]string{{a, b}, {b, a}} {
		rel, err := filepath.Rel(pair[0], pair[1])
		if err != nil || rel == "." || rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}
func safeContainerTarget(s string) bool {
	if !filepath.IsAbs(s) || filepath.Clean(s) != s || s == "/" || strings.ContainsAny(s, ",\n\r\x00") {
		return false
	}
	for _, part := range strings.Split(filepath.Clean(s), string(filepath.Separator)) {
		if part == ".." {
			return false
		}
	}
	return true
}
func validPort(s string) bool { n, e := strconv.Atoi(s); return e == nil && n > 0 && n <= 65535 }
func validLoopbackPort(s string) bool {
	host, port, e := net.SplitHostPort(s)
	if e != nil || !validPort(port) {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
