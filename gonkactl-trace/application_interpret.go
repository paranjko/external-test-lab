package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type ApplicationQueryView struct {
	Node    string           `json:"node"`
	Height  int64            `json:"height"`
	Path    string           `json:"path"`
	Status  string           `json:"status"`
	Error   string           `json:"error,omitempty"`
	Sources []string         `json:"sources"`
	Digests []string         `json:"sha256"`
	Pages   []map[string]any `json:"pages,omitempty"`
}
type ApplicationReport struct {
	LogSources []ApplicationLogSource `json:"log_sources,omitempty"`
	Logs       []ApplicationLog       `json:"decision_logs,omitempty"`
	Identities []ApplicationIdentity  `json:"identities"`
	Schema     string                 `json:"schema"`
	Incident   string                 `json:"incident"`
	Chain      string                 `json:"chain"`
	Queries    []ApplicationQueryView `json:"queries"`
	Limits     []string               `json:"limits"`
}
type ApplicationIdentity struct {
	Address   string `json:"address"`
	Validator string `json:"validator"`
	Height    int64  `json:"height"`
	Source    string `json:"source"`
}

func interpretApplication(inputs []string) (*ApplicationReport, error) {
	out := &ApplicationReport{Schema: "gonka.application.v1", Limits: []string{
		"Historical heights are reported by REST, not cryptographically verified state proofs",
		"Empty legacy PoC responses are not evidence of absent PoC v2 participation",
		"A complete query is not a complete eligibility investigation; compare conflicts before deriving a cause",
		"PoC submissions, validation votes, application group weights, staking jail, and consensus signatures are separate facts",
	}}
	if len(inputs) == 0 || len(inputs) > 8 {
		return nil, fmt.Errorf("require 1–8 application datasets")
	}
	for _, input := range inputs {
		absolute, err := filepath.Abs(input)
		if err != nil {
			return nil, err
		}
		info, err := os.Stat(absolute)
		if err != nil {
			return nil, err
		}
		if info.IsDir() {
			absolute = filepath.Join(absolute, "dataset.json")
		}
		info, err = os.Stat(absolute)
		if err != nil {
			return nil, err
		}
		if info.Size() > 64<<20 {
			return nil, fmt.Errorf("oversized application dataset")
		}
		b, err := os.ReadFile(absolute)
		if err != nil {
			return nil, err
		}
		var d Dataset
		if err = json.Unmarshal(b, &d); err != nil {
			return nil, err
		}
		if out.Chain != "" && (out.Chain != d.Config.Chain || out.Incident != d.Config.Incident) {
			return nil, fmt.Errorf("mixed application chain or incident")
		}
		out.Chain = d.Config.Chain
		out.Incident = d.Config.Incident
		if len(d.Config.ApplicationRequests) == 0 {
			out.Limits = append(out.Limits, "No historical application queries configured or discovered in this dataset; PoC explanations unavailable")
		}
		if d.Config.DiscoverApplication {
			out.Limits = append(out.Limits, "Automatic discovery targets the last reported epoch group and stays inside the selected range; earlier epochs and inputs outside that range need an explicit collection")
		}
		if len(d.Config.ApplicationRequests) > 128 || len(d.Receipts) > 20000 {
			return nil, fmt.Errorf("oversized application selection")
		}
		for _, request := range d.Config.ApplicationRequests {
			q := ApplicationQueryView{Node: request.Node, Height: request.Height, Path: request.Path, Status: "gap"}
			var rs []Receipt
			for _, r := range d.Receipts {
				if r.Application == nil || r.Node != request.Node || r.Application.RequestedHeight != request.Height {
					continue
				}
				u, e := url.Parse(r.Source)
				if e != nil || strings.TrimPrefix(u.Path, "/chain-api") != request.Path {
					continue
				}
				rs = append(rs, r)
			}
			sort.Slice(rs, func(i, j int) bool { return rs[i].Application.Page < rs[j].Application.Page })
			if len(rs) == 0 {
				q.Error = "requested query has no receipts"
			}
			if len(rs) > 32 {
				return nil, fmt.Errorf("too many application pages")
			}
			for i, r := range rs {
				q.Sources = append(q.Sources, r.Path)
				if r.Error != "" {
					q.Error = r.Error
					break
				}
				if r.Application.Page != i+1 || r.Application.ReportedHeight != strconv.FormatInt(request.Height, 10) || r.Application.Complete != (i == len(rs)-1) {
					q.Error = "height or pagination completion unverified"
					break
				}
				r.localPath = filepath.Join(filepath.Dir(absolute), filepath.Base(r.Path))
				raw, e := readReceipt(r)
				if e != nil {
					q.Error = e.Error()
					break
				}
				sum := sha256.Sum256(raw)
				q.Digests = append(q.Digests, hex.EncodeToString(sum[:]))
				var body map[string]any
				decoder := json.NewDecoder(strings.NewReader(string(raw)))
				decoder.UseNumber()
				if e = decoder.Decode(&body); e != nil || body == nil {
					q.Error = "retained application JSON invalid"
					break
				}
				if len(raw) > 256<<10 {
					q.Error = "query body exceeds presentation budget; inspect source separately"
					break
				}
				q.Pages = append(q.Pages, body)
			}
			if q.Error == "" && len(rs) > 0 {
				q.Status = "reported"
				for i, body := range q.Pages {
					for _, entry := range list(body["participant"]) {
						p := object(entry)
						key, e := base64.StdEncoding.DecodeString(str(p["validator_key"]))
						if e != nil || len(key) != 32 {
							continue
						}
						sum := sha256.Sum256(key)
						out.Identities = append(out.Identities, ApplicationIdentity{str(p["address"]), strings.ToUpper(hex.EncodeToString(sum[:20])), q.Height, q.Sources[i]})
					}
				}
			} else {
				q.Pages = nil
			}
			out.Queries = append(out.Queries, q)
		}
	}
	sort.SliceStable(out.Queries, func(i, j int) bool {
		a, b := out.Queries[i], out.Queries[j]
		if a.Height != b.Height {
			return a.Height < b.Height
		}
		if a.Path != b.Path {
			return a.Path < b.Path
		}
		return a.Node < b.Node
	})
	return out, nil
}

func runInterpret(args []string) error {
	f := flag.NewFlagSet("interpret", flag.ContinueOnError)
	inputs := f.String("application-input", "", "comma-separated application dataset.json paths")
	output := f.String("output", "", "output JSON file; default stdout")
	history := f.String("history-input", "", "retained history dataset for application decision log excerpts")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || *inputs == "" {
		return fmt.Errorf("interpret requires --application-input")
	}
	report, err := interpretApplication(strings.Split(*inputs, ","))
	if err != nil {
		return err
	}
	if *history != "" {
		for _, historyInput := range strings.Split(*history, ",") {
			if err = attachApplicationLogs(report, historyInput); err != nil {
				return err
			}
		}
	}
	if *output != "" {
		return writeJSON(*output, report)
	}
	return json.NewEncoder(os.Stdout).Encode(report)
}
