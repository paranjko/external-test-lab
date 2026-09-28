package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type ApplicationLog struct {
	Node    string            `json:"node"`
	Height  int64             `json:"height"`
	Kind    string            `json:"kind"`
	Fields  map[string]string `json:"fields"`
	Excerpt string            `json:"excerpt"`
	Source  string            `json:"source"`
	SHA256  string            `json:"sha256"`
}

type ApplicationLogSource struct {
	Node      string           `json:"node"`
	Component string           `json:"component"`
	Source    string           `json:"source"`
	Error     string           `json:"error,omitempty"`
	Bytes     int              `json:"bytes"`
	Process   *ProcessMetadata `json:"process,omitempty"`
	WindowEnd string           `json:"window_end"`
}

var applicationANSI = regexp.MustCompile(`\x1b\[[0-9;]*m`)
var applicationKV = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_.]*)=([^\s]+)`)

func parseApplicationLogs(raw []byte, node, source string, from, to int64) []ApplicationLog {
	kinds := []struct{ match, kind string }{
		{"Calculate: No majority and guardians split. Rejecting.", "poc.rejected_no_majority"},
		{"Calculate: Valid majority (slot-sampled). Accepting.", "poc.accepted_majority"},
		{"ComputeNewWeights: Added preserved-only participant", "participant.preserved"},
		{"ComputeNewWeights: Added PoC-only participant", "participant.poc"},
		{"Universal power capping applied to epoch powers", "weight.capped"},
		{" weight_pipeline ", "weight.pipeline"},
		{"samplePreservedForModel", "preservation.sample"},
		{"Calculated per-model thresholds", "preservation.thresholds"},
		{"OffChainValidator: filtered nodes for validation", "poc.worker_filter"},
		{"OffChainValidator: failed to get nodes for validation", "poc.no_workers"},
		{"updating validator power", "staking.power_update"},
		{"marking validator for removal (not in compute results)", "staking.removed"},
	}
	sum := sha256.Sum256(raw)
	digest := hex.EncodeToString(sum[:])
	out := []ApplicationLog{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 65536), maxSourceBytes)
	height := int64(0)
	line := 0
	for scanner.Scan() {
		line++
		s := applicationANSI.ReplaceAllString(scanner.Text(), "")
		fields := map[string]string{}
		for _, m := range applicationKV.FindAllStringSubmatch(s, -1) {
			fields[m[1]] = m[2]
		}
		if strings.Contains(s, "StartStage:") || strings.Contains(s, "EpochGroupChanged") || strings.Contains(s, "DapiStage:") || strings.Contains(s, "Current epoch state.") {
			if h := number(fields["blockHeight"]); h > 0 {
				height = h
			}
		}
		if strings.Contains(s, "Setting last processed height") {
			height = number(fields["height"])
		}
		if strings.Contains(s, "finalized block") || strings.Contains(s, "committed state") {
			height = 0
		}
		if height < from || height > to || height == 0 {
			continue
		}
		for _, k := range kinds {
			if strings.Contains(s, k.match) {
				out = append(out, ApplicationLog{node, height, k.kind, fields, redact(s), fmt.Sprintf("%s:%d", source, line), digest})
				break
			}
		}
	}
	return out
}
func attachApplicationLogs(report *ApplicationReport, input string) error {
	absolute, err := filepath.Abs(input)
	if err != nil {
		return err
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return err
	}
	if info.IsDir() {
		absolute = filepath.Join(absolute, "dataset.json")
	}
	b, err := os.ReadFile(absolute)
	if err != nil {
		return err
	}
	var d Dataset
	if err = json.Unmarshal(b, &d); err != nil {
		return err
	}
	if report.Chain != d.Config.Chain || report.Incident != d.Config.Incident {
		return fmt.Errorf("history chain or incident mismatch")
	}
	from, to := int64(1<<62), int64(0)
	for _, q := range report.Queries {
		if q.Height < from {
			from = q.Height
		}
		if q.Height > to {
			to = q.Height
		}
	}
	for _, r := range d.Receipts {
		if strings.HasPrefix(r.Source, "docker:") {
			component := ""
			for _, n := range d.Config.Nodes {
				if n.ID == r.Node {
					for _, s := range n.Logs {
						if r.Source == "docker:"+s.Path {
							component = s.Component
						}
					}
				}
			}
			report.LogSources = append(report.LogSources, ApplicationLogSource{r.Node, component, r.Source, r.Error, r.Bytes, r.Process, iso(d.End)})
		}
		if !strings.HasPrefix(r.Source, "docker:") || r.Bytes == 0 || r.Error != "" {
			continue
		}
		r.localPath = filepath.Join(filepath.Dir(absolute), filepath.Base(r.Path))
		raw, e := readReceipt(r)
		if e != nil {
			continue
		}
		report.Logs = append(report.Logs, parseApplicationLogs(raw, r.Node, r.Path, from, to)...)
	}
	sort.Slice(report.Logs, func(i, j int) bool {
		a, b := report.Logs[i], report.Logs[j]
		if a.Height != b.Height {
			return a.Height < b.Height
		}
		return a.Source < b.Source
	})
	return nil
}
