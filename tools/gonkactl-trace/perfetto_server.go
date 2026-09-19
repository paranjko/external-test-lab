package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed all:ui-dist
var perfettoAssets embed.FS

//go:embed ui/launcher.html
var perfettoLauncher []byte

//go:embed ui/matrix.html ui/matrix.mjs ui/matrix-i18n.mjs ui/causal.mjs
var matrixAssets embed.FS

type PFView struct {
	Schema      string          `json:"schema"`
	Fingerprint string          `json:"fingerprint"`
	Preset      string          `json:"preset"`
	Height      int64           `json:"height"`
	Round       int64           `json:"round"`
	Type        string          `json:"type"`
	Target      string          `json:"target"`
	Observer    string          `json:"observer"`
	Validator   string          `json:"validator"`
	EventID     string          `json:"event_id"`
	RoundID     string          `json:"round_id"`
	Viewport    []string        `json:"viewport_ns"`
	Tracks      []string        `json:"track_uris"`
	Collapsed   map[string]bool `json:"collapsed"`
}

func validView(v PFView) bool {
	if v.Schema != "gonka.view.v1" || v.Height < 0 || v.Round < 0 {
		return false
	}
	switch v.Preset {
	case "overview", "round", "membership", "evidence":
	default:
		return false
	}
	if len(v.Viewport) != 0 && len(v.Viewport) != 2 {
		return false
	}
	for _, x := range v.Viewport {
		if _, err := strconv.ParseUint(x, 10, 64); err != nil {
			return false
		}
	}
	if len(v.Viewport) == 2 {
		start, _ := strconv.ParseUint(v.Viewport[0], 10, 64)
		end, _ := strconv.ParseUint(v.Viewport[1], 10, 64)
		if end <= start {
			return false
		}
	}
	return true
}
func atomicArtifact(path string, b []byte) error {
	f, e := os.CreateTemp(filepath.Dir(path), ".write-*")
	if e != nil {
		return e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(tmp, path)
}
func artifactJSON(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	return atomicArtifact(path, append(b, '\n'))
}
func runPerfetto(args []string) error {
	f := flag.NewFlagSet("perfetto", flag.ContinueOnError)
	input := f.String("input", "", "sample directory or OTLP JSON")
	applicationInputs := f.String("application-input", "", "comma-separated historical application dataset.json paths")
	decisionInputs := f.String("decision-input", "", "comma-separated supplemental decision-log datasets")
	view := f.String("view", "overview", "overview, round, membership, evidence")
	height := f.Int64("height", 0, "initial height")
	round := f.Int64("round", 0, "initial round")
	noOpen := f.Bool("no-open", false, "do not open a browser")
	port := f.Int("port", 0, "loopback port, 0 chooses a free port")
	exportOnly := f.Bool("export-only", false, "write analysis and trace, then exit")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *port < 0 || *port > 65535 {
		return fmt.Errorf("invalid perfetto arguments")
	}
	state := PFView{Schema: "gonka.view.v1", Preset: *view, Height: *height, Round: *round, Collapsed: map[string]bool{}}
	if !validView(state) {
		return fmt.Errorf("invalid view, height or round")
	}
	c, fingerprint, kind, dir, e := loadPerfettoInput(*input)
	if e != nil {
		return e
	}
	if e = os.MkdirAll(dir, 0700); e != nil {
		return e
	}
	var application *ApplicationReport
	if *applicationInputs != "" {
		application, e = interpretApplication(strings.Split(*applicationInputs, ","))
		if e != nil {
			return e
		}
		if application.Chain != c.Chain || application.Incident != c.Incident {
			return fmt.Errorf("application input chain or incident mismatch")
		}
		if e = attachApplicationLogs(application, *input); e != nil {
			return e
		}
		if *decisionInputs != "" {
			for _, decisionInput := range strings.Split(*decisionInputs, ",") {
				if e = attachApplicationLogs(application, decisionInput); e != nil {
					return e
				}
			}
		}
		encoded, _ := json.Marshal(application)
		fingerprint = pfID(fingerprint, string(encoded))
		dir = filepath.Join(dir, "application-"+fingerprint)
		if e = os.MkdirAll(dir, 0700); e != nil {
			return e
		}
	}
	state.Fingerprint = fingerprint
	var a PFAnalysis
	b, readErr := os.ReadFile(filepath.Join(dir, "analysis.json"))
	cached := readErr == nil && json.Unmarshal(b, &a) == nil && a.Meta.Schema == analysisVersion && a.Meta.Fingerprint == fingerprint && a.Meta.Analyzer == analyzerVersion
	var previousManifest map[string]any
	previousBytes, manifestErr := os.ReadFile(filepath.Join(dir, "manifest.json"))
	_, recordsErr := os.Stat(filepath.Join(dir, "records.jsonl"))
	cached = cached && manifestErr == nil && recordsErr == nil && json.Unmarshal(previousBytes, &previousManifest) == nil && previousManifest["analysis_digest"] == pfID(string(b))
	if !cached {
		a = makeAnalysis(c, fingerprint, kind)
		a.Application = application
		if e = artifactJSON(filepath.Join(dir, "analysis.json"), a); e != nil {
			return e
		}
		records, e := analysisRecords(a)
		if e != nil {
			return e
		}
		if e = atomicArtifact(filepath.Join(dir, "records.jsonl"), records); e != nil {
			return e
		}
	}
	trace := nativePerfetto(a)
	oldTrace, e := os.ReadFile(filepath.Join(dir, "incident.pftrace"))
	if e != nil || pfID(string(oldTrace)) != pfID(string(trace)) {
		if e = atomicArtifact(filepath.Join(dir, "incident.pftrace"), trace); e != nil {
			return e
		}
	}
	if state.Height == 0 {
		state.Height = a.Meta.FocusHeight
	}
	viewPath := filepath.Join(dir, "view.json")
	if b, e := os.ReadFile(viewPath); e == nil {
		var saved PFView
		if json.Unmarshal(b, &saved) == nil && validView(saved) && saved.Fingerprint == fingerprint {
			state = saved
		}
	}
	if e = artifactJSON(viewPath, state); e != nil {
		return e
	}
	analysisBytes, e := os.ReadFile(filepath.Join(dir, "analysis.json"))
	if e != nil {
		return e
	}
	manifest := map[string]any{"schema": analysisVersion, "fingerprint": fingerprint, "analyzer": analyzerVersion, "perfetto_sha": "6f78923bd6e6f9bfd9078155226f76df8e0a007c", "input_kind": kind, "trace_digest": pfID(string(trace)), "analysis_digest": pfID(string(analysisBytes)), "view": state, "trace": "trace", "analysis": "analysis"}
	if e = artifactJSON(filepath.Join(dir, "manifest.json"), manifest); e != nil {
		return e
	}
	fmt.Fprintf(os.Stderr, "Perfetto artifacts: %s; events=%d observations=%d gaps=%d cache=%t\n", dir, len(a.Events), len(a.Observations), len(a.Coverage), cached)
	if *exportOnly {
		return writeHTMLReport(dir, a)
	}
	assets, e := fs.Sub(perfettoAssets, "ui-dist")
	if e != nil {
		return e
	}
	if _, e = fs.Stat(assets, "index.html"); e != nil {
		return fmt.Errorf("offline Perfetto assets missing: build with make release; exports remain at %s", dir)
	}
	listener, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if e != nil {
		return e
	}
	origin := "http://" + listener.Addr().String()
	handler := perfettoHandler(origin, fingerprint, dir, a, assets)
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	url := origin + "/gonka/?session=" + fingerprint
	fmt.Fprintln(os.Stderr, url)
	if !*noOpen {
		if e = openBrowser(url); e != nil {
			fmt.Fprintln(os.Stderr, "Browser could not be opened; use URL above:", e)
		}
	}
	select {
	case <-ctx.Done():
		shutdown, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		return server.Shutdown(shutdown)
	case e := <-done:
		if errors.Is(e, http.ErrServerClosed) {
			return nil
		}
		return e
	}
}
func openBrowser(url string) error {
	command := "xdg-open"
	if runtime.GOOS == "darwin" {
		command = "open"
	}
	cmd := exec.Command(command, url)
	if e := cmd.Start(); e != nil {
		return e
	}
	go func() { _ = cmd.Wait() }()
	return nil
}
func perfettoHandler(origin, id, dir string, a PFAnalysis, assets fs.FS) http.Handler {
	mux := http.NewServeMux()
	base := "/api/session/" + id + "/"
	matrix := matrixSubset(a)
	var mu sync.Mutex
	sources := map[string]PFObservation{}
	for _, o := range a.Observations {
		sources[o.ID] = o
	}
	mux.HandleFunc(base, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		name := strings.TrimPrefix(r.URL.Path, base)
		if name == "view" && r.Method == http.MethodPut {
			if r.Header.Get("Origin") != origin {
				http.Error(w, "same-origin required", 403)
				return
			}
			var v PFView
			d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10))
			d.DisallowUnknownFields()
			if e := d.Decode(&v); e != nil || !validView(v) || v.Fingerprint != id {
				http.Error(w, "invalid view", 400)
				return
			}
			var extra any
			if d.Decode(&extra) != io.EOF {
				http.Error(w, "trailing JSON", 400)
				return
			}
			mu.Lock()
			e := artifactJSON(filepath.Join(dir, "view.json"), v)
			mu.Unlock()
			if e != nil {
				http.Error(w, "cannot save view", 500)
				return
			}
			w.WriteHeader(204)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", 405)
			return
		}
		switch name {
		case "matrix":
			_ = json.NewEncoder(w).Encode(matrix)
		case "manifest", "analysis", "view":
			mu.Lock()
			b, e := os.ReadFile(filepath.Join(dir, name+".json"))
			mu.Unlock()
			if e != nil {
				http.Error(w, "artifact unavailable", 404)
				return
			}
			_, _ = w.Write(b)
		case "trace":
			w.Header().Set("Content-Type", "application/octet-stream")
			http.ServeFile(w, r, filepath.Join(dir, "incident.pftrace"))
		default:
			if strings.HasPrefix(name, "evidence/") {
				o, ok := sources[strings.TrimPrefix(name, "evidence/")]
				if ok {
					_ = json.NewEncoder(w).Encode(o)
					return
				}
			}
			http.NotFound(w, r)
		}
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/gonka/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/gonka/matrix.mjs" || r.URL.Path == "/gonka/matrix-i18n.mjs" || r.URL.Path == "/gonka/causal.mjs" {
			w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			b, _ := matrixAssets.ReadFile("ui/" + filepath.Base(r.URL.Path))
			_, _ = w.Write(b)
			return
		}
		if r.URL.Path != "/gonka/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		if r.URL.Query().Get("view") == "timeline" {
			_, _ = w.Write(perfettoLauncher)
		} else {
			b, _ := matrixAssets.ReadFile("ui/matrix.html")
			_, _ = w.Write(b)
		}
	})
	_ = mime.AddExtensionType(".wasm", "application/wasm")
	mux.Handle("/", http.FileServer(http.FS(assets)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if "http://"+r.Host != origin {
			http.Error(w, "invalid host", 403)
			return
		}
		if o := r.Header.Get("Origin"); o != "" && o != origin {
			http.Error(w, "invalid origin", 403)
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self' blob: data:; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' blob:; worker-src 'self' blob:; frame-ancestors 'self'; object-src 'none'")
		mux.ServeHTTP(w, r)
	})
}
