package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func runReport(args []string) error {
	f := flag.NewFlagSet("report", flag.ContinueOnError)
	input := f.String("input", "", "offline dataset directory or dataset.json; no collection")
	config := f.String("config", "gonkactl-trace.json", "collection configuration")
	apps := f.String("application-input", "", "optional retained supplemental application datasets")
	logs := f.String("decision-input", "", "optional retained supplemental log datasets")
	if err := f.Parse(args); err != nil {
		return err
	}
	if *input != "" {
		if f.NArg() != 0 {
			return fmt.Errorf("offline --input cannot be combined with block heights")
		}
	} else {
		if *apps != "" || *logs != "" {
			return fmt.Errorf("supplemental inputs require offline --input")
		}
		c, from, to, err := collectionArguments(f.Args(), *config)
		if err != nil {
			return err
		}
		c.DiscoverApplication = true
		fmt.Fprintf(os.Stderr, "report: collect %d %d\n", from, to)
		if err = collectWithResult(c, from, to, func(path string) { *input = path }); err != nil {
			return err
		}
	}
	if *apps == "" {
		*apps = *input
	}
	return runPerfetto([]string{"--input", *input, "--application-input", *apps, "--decision-input", *logs, "--export-only"})
}

func sha256Hex(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// Inline the same modules used by the server. No fetch, CDN, local server or
// Perfetto installation is needed to open the report. JSON encoding escapes
// '<', so retained source text cannot terminate its inert script element.
func standaloneHTML(m PFMatrix) ([]byte, error) {
	body, err := matrixAssets.ReadFile("ui/matrix.html")
	if err != nil {
		return nil, err
	}
	data, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	var modules []string
	for _, name := range []string{"matrix-i18n.mjs", "causal.mjs", "matrix.mjs"} {
		b, e := matrixAssets.ReadFile("ui/" + name)
		if e != nil {
			return nil, e
		}
		lines := strings.Split(string(b), "\n")
		for i, line := range lines {
			if strings.HasPrefix(line, "import ") {
				lines[i] = ""
			}
		}
		modules = append(modules, strings.Join(lines, "\n"))
	}
	script := strings.Join(modules, "\n")
	if strings.Contains(strings.ToLower(script), "</script") {
		return nil, fmt.Errorf("unsafe inline module terminator")
	}
	replacement := `<script id="gonka-report-data" type="application/json">` + string(data) + `</script><script type="module">` + script + `</script>`
	return []byte(strings.Replace(string(body), `<script type="module" src="/gonka/matrix.mjs"></script>`, replacement, 1)), nil
}

func writeHTMLReport(dir string, a PFAnalysis) error {
	m := matrixSubset(a)
	b, err := standaloneHTML(m)
	if err != nil {
		return err
	}
	if err = atomicArtifact(filepath.Join(dir, "report.html"), b); err != nil {
		return err
	}
	if err = artifactJSON(filepath.Join(dir, "matrix.json"), m); err != nil {
		return err
	}
	manifest := map[string]any{"schema": "gonka.report.v1", "fingerprint": a.Meta.Fingerprint, "analyzer": analyzerVersion, "files": map[string]string{}, "reproduction": "gonkactl-trace report --input <retained dataset.json>; same binary and retained inputs required"}
	for _, name := range []string{"report.html", "matrix.json", "analysis.json", "incident.pftrace"} {
		bytes, e := os.ReadFile(filepath.Join(dir, name))
		if e != nil {
			return e
		}
		manifest["files"].(map[string]string)[name] = sha256Hex(bytes)
	}
	if err = artifactJSON(filepath.Join(dir, "report-manifest.json"), manifest); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "HTML report:", filepath.Join(dir, "report.html"))
	return nil
}
