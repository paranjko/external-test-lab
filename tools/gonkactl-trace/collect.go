package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxSourceBytes = 16 << 20

var safeID = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

type rpcResult struct {
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}
type collector struct {
	d      Dataset
	dir    string
	mu     sync.Mutex
	client *http.Client
}

func collect(c Config, from, to int64) error {
	return collectWithResult(c, from, to, nil)
}

// The callback receives this invocation's sealed dataset, never a shared latest pointer.
func collectWithResult(c Config, from, to int64, done func(string)) error {
	seen := map[string]bool{}
	for _, n := range c.Nodes {
		if !safeID.MatchString(n.ID) || seen[n.ID] {
			return fmt.Errorf("invalid or duplicate node ID")
		}
		seen[n.ID] = true
		if n.SSH != "" && !safeID.MatchString(n.SSH) {
			return fmt.Errorf("invalid SSH alias")
		}
	}
	if e := os.MkdirAll(datasetDir, 0700); e != nil {
		return e
	}
	dir, e := os.MkdirTemp(datasetDir, "sample-")
	if e != nil {
		return e
	}
	x := collector{dir: dir, d: Dataset{Config: c, From: from, To: to, Collected: time.Now().UTC()}, client: &http.Client{Timeout: time.Duration(c.TimeoutSeconds) * time.Second}}
	jobs := make(chan func())
	var wg sync.WaitGroup
	for i := 0; i < c.Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range jobs {
				f()
			}
		}()
	}
	for _, n := range c.Nodes {
		if len(c.History) > 0 {
			for _, request := range c.History {
				if request.Node == n.ID {
					request, n := request, n
					jobs <- func() { x.rpc(n, request.Method, request.Height) }
				}
			}
		} else {
			for h := from; h <= to; h++ {
				for _, method := range []string{"block", "commit", "block_results", "validators"} {
					n, h, method := n, h, method
					jobs <- func() { x.rpc(n, method, h) }
				}
			}
		}
		n := n
		for i, request := range c.ApplicationRequests {
			if request.Node == n.ID {
				i, request := i, request
				jobs <- func() { x.application(n, request, i) }
			}
		}
		hasNext := false
		for _, request := range c.History {
			if request.Node == n.ID && request.Method == "validators" && request.Height == to+1 {
				hasNext = true
				break
			}
		}
		if !hasNext {
			jobs <- func() { x.rpc(n, "validators", to+1) }
		}
		for _, m := range []string{"status", "abci_info", "consensus_state", "dump_consensus_state"} {
			m := m
			jobs <- func() { x.rpc(n, m, 0) }
		}
	}
	close(jobs)
	wg.Wait()
	if c.DiscoverApplication {
		if e := x.discoverApplication(); e != nil {
			return e
		}
	}
	for _, ev := range x.d.Events {
		if ev.Type == "block.commit" && !ev.Current && !ev.Time.IsZero() {
			if x.d.Start.IsZero() || ev.Time.Before(x.d.Start) {
				x.d.Start = ev.Time
			}
			if ev.Time.After(x.d.End) {
				x.d.End = ev.Time
			}
		}
	}
	jobs = make(chan func())
	for i := 0; i < c.Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for f := range jobs {
				f()
			}
		}()
	}
	for _, n := range c.Nodes {
		for i, s := range n.Logs {
			n, i, s := n, i, s
			jobs <- func() { x.logs(n, i, s) }
		}
	}
	close(jobs)
	wg.Wait()
	if e := rebuildEvents(&x.d); e != nil {
		return e
	}
	if e := writeJSON(filepath.Join(dir, "dataset.json"), x.d); e != nil {
		return e
	}
	if e := writeJSON(filepath.Join(dir, "summary.json"), summarize(x.d)); e != nil {
		return e
	}
	// Publish the latest pointer only after a complete dataset has been written.
	tmp := filepath.Join(dir, "latest.json")
	if e := writeJSON(tmp, x.d); e != nil {
		return e
	}
	if e := os.Rename(tmp, datasetDir+"/latest.json"); e != nil {
		return e
	}
	b, _ := json.MarshalIndent(summarize(x.d), "", "  ")
	fmt.Fprintln(os.Stderr, string(b))
	fmt.Fprintln(os.Stderr, "dataset:", dir)
	if done != nil {
		done(filepath.Join(dir, "dataset.json"))
	}
	return nil
}
func (x *collector) save(n Node, name, source string, b []byte, err error, events []Event, at time.Time, process ...*ProcessMetadata) {
	path := filepath.Join(x.dir, n.ID+"-"+name)
	r := Receipt{Node: n.ID, Source: source, Path: path, Collected: at, Bytes: len(b)}
	if len(process) > 0 {
		r.Process = process[0]
	}
	if len(b) > 0 {
		b = redactSource(b)
		if e := os.WriteFile(path, b, 0600); e != nil {
			err = fmt.Errorf("%v; save: %w", err, e)
		}
	}
	if err != nil {
		r.Error = redact(err.Error())
	}
	x.mu.Lock()
	defer x.mu.Unlock()
	x.d.Receipts = append(x.d.Receipts, r)
	x.d.Events = append(x.d.Events, events...)
}
func (x *collector) rpc(n Node, method string, h int64) {
	vals := []map[string]any{}
	complete := false
	var expected int64
	for page := 1; page <= 1000; page++ {
		q := url.Values{}
		if h > 0 {
			q.Set("height", strconv.FormatInt(h, 10))
		}
		if method == "validators" {
			q.Set("per_page", "100")
			q.Set("page", strconv.Itoa(page))
		}
		endpoint := strings.TrimRight(n.RPC, "/") + "/" + method + "?" + q.Encode()
		name := fmt.Sprintf("%s-%d-%d.json", method, h, page)
		ref := filepath.Join(x.dir, n.ID+"-"+name)
		at := time.Now().UTC()
		var b []byte
		var err error
		u, e := url.Parse(endpoint)
		if e != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil {
			err = fmt.Errorf("invalid RPC URL")
		} else {
			var resp *http.Response
			resp, err = x.client.Get(endpoint)
			if err == nil {
				b, err = io.ReadAll(io.LimitReader(resp.Body, maxSourceBytes+1))
				resp.Body.Close()
				if len(b) > maxSourceBytes {
					b = nil
					err = fmt.Errorf("RPC response exceeds limit")
				}
				if resp.StatusCode != 200 {
					err = fmt.Errorf("HTTP %d", resp.StatusCode)
				}
			}
		}
		var result rpcResult
		var events []Event
		if err == nil {
			err = json.Unmarshal(b, &result)
			if err == nil && (len(result.Result) == 0 || string(result.Result) == "null") {
				err = fmt.Errorf("RPC result missing")
			}
			if err == nil && len(result.Error) > 0 && string(result.Error) != "null" {
				err = fmt.Errorf("RPC error: %s", result.Error)
			}
		}
		if err == nil {
			events = normalizeRPC(method, result.Result, n.ID, h, ref, at)
		}
		x.save(n, name, endpoint, b, err, events, at)
		if err != nil {
			return
		}
		if method != "validators" {
			return
		}
		var vr struct {
			Validators  []map[string]any `json:"validators"`
			Total       string           `json:"total"`
			BlockHeight string           `json:"block_height"`
		}
		if json.Unmarshal(result.Result, &vr) != nil {
			return
		}
		total, e := strconv.ParseInt(vr.Total, 10, 64)
		if e != nil || total < 0 || vr.BlockHeight != strconv.FormatInt(h, 10) {
			return
		}
		if page == 1 {
			expected = total
		}
		if expected != total {
			return
		}
		vals = append(vals, vr.Validators...)
		if int64(len(vals)) == total {
			complete = true
			break
		}
		if len(vr.Validators) == 0 || int64(len(vals)) > total {
			return
		}
	}
	if complete {
		total := int64(0)
		identities := map[string]bool{}
		for _, v := range vals {
			addr := str(v["address"])
			p, e := strconv.ParseInt(str(v["voting_power"]), 10, 64)
			if e != nil || p < 0 || p > 1<<50 || addr == "" || identities[addr] {
				return
			}
			identities[addr] = true
			total += p
		}
		ev := Event{Node: n.ID, Component: "cometbft", Type: "validators.set", Height: h, Source: filepath.Join(x.dir, fmt.Sprintf("%s-validators-%d-*.json", n.ID, h)), Attr: map[string]string{"voting_power.total": strconv.FormatInt(total, 10), "validators.complete": "true", "validators.count": strconv.Itoa(len(vals))}}
		x.mu.Lock()
		x.d.Events = append(x.d.Events, ev)
		x.mu.Unlock()
	}
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func safeLogPath(p string) bool {
	l := strings.ToLower(p)
	return (strings.HasSuffix(l, ".log") || strings.HasSuffix(l, ".jsonl") || strings.HasSuffix(l, ".txt")) && !strings.Contains(l, "key") && !strings.Contains(l, "secret") && !strings.Contains(l, "credential") && !strings.Contains(l, ".env")
}
func (x *collector) logs(n Node, i int, s LogSource) {
	at := time.Now().UTC()
	var b []byte
	var err error
	var command string
	var process *ProcessMetadata
	pad := time.Duration(x.d.Config.PaddingSeconds) * time.Second
	start, end := x.d.Start.Add(-pad), x.d.End.Add(pad)
	switch s.Kind {
	case "local":
		if !safeLogPath(s.Path) {
			err = fmt.Errorf("only explicitly named non-secret log files allowed")
		} else {
			info, e := os.Lstat(s.Path)
			if e != nil {
				err = e
			} else if !info.Mode().IsRegular() {
				err = fmt.Errorf("local log must be a regular non-symlink file")
			}
			if err != nil {
				break
			}
			var f *os.File
			f, err = os.Open(s.Path)
			if err == nil {
				b, err = io.ReadAll(io.LimitReader(f, maxSourceBytes+1))
				f.Close()
			}
		}
	case "docker":
		if !safeID.MatchString(s.Path) {
			err = fmt.Errorf("invalid container name")
		} else {
			process = inspectProcess(n.SSH, s.Path, x.d.Config.TimeoutSeconds)
			command = "docker logs --timestamps "
			if !x.d.Start.IsZero() {
				command += "--since " + quote(start.Format(time.RFC3339Nano)) + " --until " + quote(end.Format(time.RFC3339Nano)) + " "
			} else {
				command += "--tail 100000 "
			}
			command += quote(s.Path) + " 2>&1"
		}
	case "journal":
		if !safeID.MatchString(s.Path) {
			err = fmt.Errorf("invalid unit name")
		} else {
			command = "journalctl --no-pager -o short-iso-precise -n 100000 -u " + quote(s.Path)
			if !x.d.Start.IsZero() {
				command += " --since " + quote(start.Format(time.RFC3339)) + " --until " + quote(end.Format(time.RFC3339))
			}
		}
	case "file":
		if !safeLogPath(s.Path) {
			err = fmt.Errorf("only explicit non-secret log paths allowed")
		} else {
			command = "tail -c 16777216 -- " + quote(s.Path)
		}
	default:
		err = fmt.Errorf("unknown log kind %q", s.Kind)
	}
	if command != "" && err == nil {
		if n.SSH == "" {
			err = fmt.Errorf("SSH alias not configured")
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(x.d.Config.TimeoutSeconds)*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", n.SSH, command)
			buf := &boundedBuffer{limit: maxSourceBytes}
			cmd.Stdout = buf
			cmd.Stderr = buf
			err = cmd.Run()
			b = buf.b
			if buf.overflow {
				err = fmt.Errorf("log source truncated at %d bytes", maxSourceBytes)
			}
		}
	}
	if len(b) > maxSourceBytes {
		b = b[:maxSourceBytes]
		err = fmt.Errorf("log source truncated")
	}
	if len(b) == 0 && err == nil {
		err = fmt.Errorf("no retained log records in requested window")
	}
	name := fmt.Sprintf("log-%d.txt", i)
	ref := filepath.Join(x.dir, n.ID+"-"+name)
	events := normalizeLog(string(b), n.ID, s.Component, ref, x.d.From, x.d.To, start, end, !x.d.Start.IsZero())
	x.save(n, name, s.Kind+":"+s.Path, b, err, events, at, process)
}

type boundedBuffer struct {
	b        []byte
	limit    int
	overflow bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	remaining := b.limit - len(b.b)
	if n > remaining {
		b.overflow = true
		p = p[:remaining]
	}
	b.b = append(b.b, p...)
	return n, nil
}
