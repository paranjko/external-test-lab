package main

import (
	"encoding/json"
	"fmt"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"os"
	"time"
)

const datasetDir = ".gonkactl-trace"

type Config struct {
	DiscoverApplication bool                 `json:"discover_application,omitempty"`
	ApplicationRequests []ApplicationRequest `json:"application_requests,omitempty"`
	LogDetailRanges     []HeightRange        `json:"log_detail_ranges,omitempty"`
	IdentityLabels      []InventoryLabel     `json:"identity_labels,omitempty"`
	History             []HistoryRequest     `json:"history_requests,omitempty"`
	Incident            string               `json:"incident"`
	Chain               string               `json:"chain"`
	PaddingSeconds      int                  `json:"padding_seconds"`
	TimeoutSeconds      int                  `json:"timeout_seconds"`
	Concurrency         int                  `json:"concurrency"`
	Nodes               []Node               `json:"nodes"`
}
type Node struct {
	REST string      `json:"rest,omitempty"`
	ID   string      `json:"id"`
	RPC  string      `json:"rpc"`
	SSH  string      `json:"ssh,omitempty"`
	Logs []LogSource `json:"logs,omitempty"`
}
type LogSource struct {
	Component string `json:"component"`
	Kind      string `json:"kind"`
	Path      string `json:"path"`
}
type Event struct {
	Time              time.Time         `json:"time"`
	OriginalTimestamp string            `json:"original_timestamp,omitempty"`
	Node              string            `json:"node"`
	Component         string            `json:"component"`
	Type              string            `json:"type"`
	Message           string            `json:"message"`
	Source            string            `json:"source"`
	Height            int64             `json:"height,omitempty"`
	Round             *int64            `json:"round,omitempty"`
	Current           bool              `json:"current_observation,omitempty"`
	Inferred          bool              `json:"time_inferred,omitempty"`
	Attr              map[string]string `json:"attributes,omitempty"`
}
type Receipt struct {
	Application *ApplicationEvidence `json:"application,omitempty"`
	Process     *ProcessMetadata     `json:"process,omitempty"`
	localPath   string
	Node        string    `json:"node"`
	Source      string    `json:"source"`
	Path        string    `json:"path"`
	Collected   time.Time `json:"collected"`
	Error       string    `json:"error,omitempty"`
	Bytes       int       `json:"bytes"`
}
type Dataset struct {
	Config    Config    `json:"config"`
	From      int64     `json:"from"`
	To        int64     `json:"to"`
	Collected time.Time `json:"collected"`
	Start     time.Time `json:"start"`
	End       time.Time `json:"end"`
	Receipts  []Receipt `json:"receipts"`
	Events    []Event   `json:"events"`
}

func writeJSON(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	return os.WriteFile(path, append(b, '\n'), 0600)
}
func main() {
	if e := execute(os.Args[1:]); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func execute(args []string) error {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "help" || args[0] == "-h") {
		fmt.Println("gonkactl-trace (experimental)\n\nreport [--config file] <from> [to]   collect and write an HTML report\nreport --input dataset.json        rebuild offline from retained sources\ncollect <from> [to]                collect using gonkactl-trace.json\ninterpret --help                  inspect application evidence options\nperfetto --help                   inspect native trace/viewer options\notlp | otlp-consensus             export the latest collection locally\nrun | run-consensus               upload the latest collection to TraceKit\n\nReports and collected data are private by default. Read README.md before collecting or uploading.")
		return nil
	}
	if len(args) > 0 && args[0] == "report" {
		return runReport(args[1:])
	}
	if len(args) > 0 && args[0] == "interpret" {
		return runInterpret(args[1:])
	}
	if len(args) > 0 && args[0] == "perfetto" {
		return runPerfetto(args[1:])
	}
	if len(args) == 0 {
		return fmt.Errorf("usage: gonkactl-trace report <from> [to] | collect <from> [to] | perfetto | interpret | otlp | otlp-consensus | run | run-consensus; see --help")
	}
	if args[0] == "collect" {
		c, from, to, e := collectionArguments(args[1:], "gonkactl-trace.json")
		if e != nil {
			return e
		}
		return collect(c, from, to)
	}
	if len(args) != 1 || (args[0] != "run" && args[0] != "otlp" && args[0] != "run-consensus" && args[0] != "otlp-consensus") {
		return fmt.Errorf("unknown command or extra arguments")
	}
	var d Dataset
	b, e := os.ReadFile(datasetDir + "/latest.json")
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &d); e != nil {
		return e
	}
	if e = rebuildEvents(&d); e != nil {
		return e
	}
	if args[0] == "run-consensus" || args[0] == "otlp-consensus" {
		c, err := buildConsensus(d)
		if err != nil {
			return err
		}
		if err = writeJSON(datasetDir+"/consensus-timeline.json", c); err != nil {
			return err
		}
		if args[0] == "run-consensus" {
			return replayProjection(c.End, func(shift time.Duration, id string) (ptrace.Traces, error) { return consensusTrace(c, shift, id) })
		}
		t, err := consensusTrace(c, 0, "")
		if err != nil {
			return err
		}
		data, err := marshalTrace(t)
		if err != nil {
			return err
		}
		_, err = os.Stdout.Write(append(data, '\n'))
		return err
	}
	if e = writeJSON(datasetDir+"/analysis-summary.json", summarize(d)); e != nil {
		return e
	}
	if args[0] == "run" {
		return replay(d)
	}
	t, e := buildTrace(d, 0, "")
	if e != nil {
		return e
	}
	historical, current := splitTrace(t)
	if current.SpanCount() > 0 {
		diagnostic, err := marshalTrace(current)
		if err != nil {
			return err
		}
		if err = os.WriteFile(datasetDir+"/current-observations.otlp.json", diagnostic, 0600); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "current snapshots:", datasetDir+"/current-observations.otlp.json")
	}
	if historical.SpanCount() == 0 {
		return fmt.Errorf("no historically anchored events; current snapshots exported separately")
	}
	b, e = marshalTrace(historical)
	if e != nil {
		return e
	}
	_, e = os.Stdout.Write(append(b, '\n'))
	return e
}
