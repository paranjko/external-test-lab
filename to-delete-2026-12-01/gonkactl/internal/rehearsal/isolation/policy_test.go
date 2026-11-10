package isolation

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type fakeRunner struct{ got Command }

func (f *fakeRunner) Run(_ context.Context, c Command) ([]byte, []byte, int, error) {
	f.got = c
	return nil, nil, 0, nil
}

func binding(t *testing.T) contract.RunBinding {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{"source", "control", "fork-a", "fork-b", "evidence"} {
		if err := os.Mkdir(filepath.Join(root, d), 0700); err != nil {
			t.Fatal(err)
		}
	}
	h := int64(1)
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: "r1", Scenario: contract.Scenario, Workspace: root, OwnershipMarker: "owner-r1", ChainID: "fixture", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 2, App: 1, Consensus: &h, FirstRepaired: 2}, BlockID: "block", AppHash: "app", AppHashHeight: 1, ToolVersion: "test", CatalogVersion: "fixture", InputDigests: map[string]string{"source": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"runtime": "fixture"}, Paths: map[string]string{"source": filepath.Join(root, "source"), "control": filepath.Join(root, "control"), "fork-a": filepath.Join(root, "fork-a"), "fork-b": filepath.Join(root, "fork-b"), "evidence": filepath.Join(root, "evidence")}}
}
func spec(t *testing.T, b contract.RunBinding) ContainerSpec {
	t.Helper()
	d, err := contract.Digest(b)
	if err != nil {
		t.Fatal(err)
	}
	return ContainerSpec{Name: "fork-a", Image: "registry.invalid/node@sha256:" + strings.Repeat("a", 64), Argv: []string{"node", "start"}, Mounts: []Mount{{PathKey: "source", Target: "/source", ReadOnly: true}, {PathKey: "control", Target: "/control", ReadOnly: true}, {PathKey: "evidence", Target: "/evidence", ReadOnly: true}, {PathKey: "fork-a", Target: "/data", ReadOnly: false}}, Ports: []Port{{Container: "26657", Host: "127.0.0.1:26657"}}, Labels: map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": d}}
}
func TestCommandUsesArgvAndExplicitSafeMounts(t *testing.T) {
	b := binding(t)
	s := spec(t, b)
	c, err := s.createCommand("docker", b)
	if err != nil {
		t.Fatal(err)
	}
	if c.Executable() != "docker" {
		t.Fatalf("executable: %+v", c)
	}
	joined := strings.Join(c.Args(), " ")
	for _, want := range []string{"--network none", "type=bind,src=" + b.Paths["source"] + ",dst=/source,readonly", "type=bind,src=" + b.Paths["fork-a"] + ",dst=/data,rw", "127.0.0.1:26657:26657"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in %s", want, joined)
		}
	}
	f := &fakeRunner{}
	_, _, code, err := f.Run(context.Background(), c)
	if err != nil || code != 0 || len(f.got.Args()) == 0 {
		t.Fatalf("fake runner failed: %v, %d", err, code)
	}
}
func TestRejectsUnsafeMountsLabelsPortsAndImages(t *testing.T) {
	b := binding(t)
	base := spec(t, b)
	cases := map[string]func(*ContainerSpec){
		"arbitrary host mount":   func(s *ContainerSpec) { s.Mounts[0].PathKey = "../../etc" },
		"writable source":        func(s *ContainerSpec) { s.Mounts[0].ReadOnly = false },
		"readonly fork":          func(s *ContainerSpec) { s.Mounts[3].ReadOnly = true },
		"target traversal":       func(s *ContainerSpec) { s.Mounts[0].Target = "/safe/../etc" },
		"wrong target":           func(s *ContainerSpec) { s.Mounts[0].Target = "/etc" },
		"csv injection":          func(s *ContainerSpec) { s.Mounts[0].Target = "/safe,readonly" },
		"host networking":        func(s *ContainerSpec) { s.HostNetwork = true },
		"host pid":               func(s *ContainerSpec) { s.HostPID = true },
		"privileged":             func(s *ContainerSpec) { s.Privileged = true },
		"digest too short":       func(s *ContainerSpec) { s.Image = "node@sha256:x" },
		"digest nonhex":          func(s *ContainerSpec) { s.Image = "node@sha256:" + strings.Repeat("z", 64) },
		"wrong ownership":        func(s *ContainerSpec) { s.Labels["gonka.rehearsal.owner"] = "other" },
		"extra label":            func(s *ContainerSpec) { s.Labels["arbitrary"] = "value" },
		"option name injection":  func(s *ContainerSpec) { s.Name = "--privileged" },
		"image option injection": func(s *ContainerSpec) { s.Image = "--privileged@sha256:" + strings.Repeat("a", 64) },
		"duplicate mount":        func(s *ContainerSpec) { s.Mounts = append(s.Mounts, s.Mounts[0]) },
		"nonlocal port":          func(s *ContainerSpec) { s.Ports[0].Host = "0.0.0.0:26657" },
		"invalid port":           func(s *ContainerSpec) { s.Ports[0].Host = "127.0.0.1:99999" },
		"duplicate port":         func(s *ContainerSpec) { s.Ports = append(s.Ports, s.Ports[0]) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			s := base
			s.Mounts = append([]Mount(nil), base.Mounts...)
			s.Ports = append([]Port(nil), base.Ports...)
			s.Labels = map[string]string{}
			for k, v := range base.Labels {
				s.Labels[k] = v
			}
			mutate(&s)
			if _, err := s.createCommand("docker", b); err == nil {
				t.Fatal("unsafe spec accepted")
			}
		})
	}
	link := filepath.Join(b.Workspace, "link")
	if err := os.Symlink(b.Paths["source"], link); err != nil {
		t.Fatal(err)
	}
	b.Paths["source"] = link
	if err := spec(t, b).ValidateBinding(b); err == nil {
		t.Fatal("symlink mount source accepted")
	}
	b = binding(t)
	commaPath := filepath.Join(b.Workspace, "x,y")
	if err := os.Mkdir(commaPath, 0700); err != nil {
		t.Fatal(err)
	}
	b.Paths["source"] = commaPath
	if err := spec(t, b).ValidateBinding(b); err == nil {
		t.Fatal("CSV source path accepted")
	}
	b = binding(t)
	b.Paths["fork-a"] = filepath.Join(b.Paths["source"], "nested")
	if err := os.Mkdir(b.Paths["fork-a"], 0700); err != nil {
		t.Fatal(err)
	}
	if err := spec(t, b).ValidateBinding(b); err == nil {
		t.Fatal("overlapping source/fork paths accepted")
	}
}
func TestCleanupRequiresExactOwnedInventory(t *testing.T) {
	b := binding(t)
	d, _ := contract.Digest(b)
	labels := map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": d}
	if err := ValidateCleanup(b, []string{"owned"}, []Resource{{ID: "owned", Labels: labels}}); err != nil {
		t.Fatal(err)
	}
	for name, ids := range map[string][]string{"foreign consumer": nil, "foreign id": []string{"foreign"}, "missing resource": []string{"owned", "missing"}} {
		t.Run(name, func(t *testing.T) {
			r := Resource{ID: "owned", Labels: labels}
			if name == "foreign consumer" {
				r.Consumers = []string{"someone"}
			}
			if err := ValidateCleanup(b, ids, []Resource{r}); err == nil {
				t.Fatal("unsafe cleanup accepted")
			}
		})
	}
	if err := ValidateCleanup(b, []string{"owned"}, []Resource{{ID: "owned", Labels: map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": "other", "gonka.rehearsal.binding": d}}}); err == nil {
		t.Fatal("same-run different-owner resource accepted")
	}
}
func TestProbeEvidenceBoundAndStrict(t *testing.T) {
	b := binding(t)
	d, _ := contract.Digest(b)
	runtime := "fixture"
	makeResults := func() []ProbeResult {
		out := []ProbeResult{}
		for _, domain := range RequiredProbeDomains() {
			evidence := []byte("fixture evidence for " + string(domain))
			out = append(out, ProbeResult{Domain: domain, Isolated: true, Evidence: evidence, EvidenceDigest: contract.PayloadDigest(evidence), RunID: b.RunID, BindingDigest: d, RuntimeID: runtime, Phase: Launch})
		}
		return out
	}
	if err := ValidateProbeEvidence(b, runtime, Launch, makeResults()); err != nil {
		t.Fatal(err)
	}
	handoff := makeResults()
	for i := range handoff {
		handoff[i].Phase = Handoff
	}
	if err := ValidateProbeEvidence(b, runtime, Handoff, handoff); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func([]ProbeResult) []ProbeResult{"missing": func(p []ProbeResult) []ProbeResult { return p[:len(p)-1] }, "duplicate": func(p []ProbeResult) []ProbeResult { p[1] = p[0]; return p }, "contradictory duplicate": func(p []ProbeResult) []ProbeResult { p[1] = p[0]; p[1].Isolated = false; return p }, "unknown": func(p []ProbeResult) []ProbeResult { p[0].Domain = "other"; return p }, "failed": func(p []ProbeResult) []ProbeResult { p[0].Isolated = false; return p }, "fake digest": func(p []ProbeResult) []ProbeResult { p[0].EvidenceDigest = "success"; return p }, "mismatched digest": func(p []ProbeResult) []ProbeResult { p[0].EvidenceDigest = strings.Repeat("c", 64); return p }, "wrong run": func(p []ProbeResult) []ProbeResult { p[0].RunID = "r2"; return p }, "wrong binding": func(p []ProbeResult) []ProbeResult { p[0].BindingDigest = strings.Repeat("c", 64); return p }, "wrong runtime": func(p []ProbeResult) []ProbeResult { p[0].RuntimeID = "other"; return p }, "wrong phase": func(p []ProbeResult) []ProbeResult { p[0].Phase = Handoff; return p }}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if err := ValidateProbeEvidence(b, runtime, Launch, mutate(makeResults())); err == nil {
				t.Fatal("invalid probe evidence accepted")
			}
		})
	}
}
