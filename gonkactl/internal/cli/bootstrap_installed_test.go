package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/bootstrap"
)

// Exercise the actual executable outside its checkout, without a usable PATH,
// inherited operator environment, shell helpers or outbound-network fixtures.
func TestInstalledBootstrapLifecycle(t *testing.T) {
	workspace := t.TempDir()
	binary := filepath.Join(workspace, "gonkactl")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	build := exec.Command("go", "build", "-buildvcs=false", "-o", binary, "./cmd/gonkactl")
	build.Dir = filepath.Join("..", "..")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, output)
	}
	home, outputDir := filepath.Join(workspace, "home"), filepath.Join(workspace, "output")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	genesis := `{"chain_id":"fixture"}`
	digest := sha256.Sum256([]byte(genesis))
	doc := bootstrap.Document{Schema: bootstrap.SchemaURL, ChainID: "fixture"}
	doc.Genesis.SHA256 = hex.EncodeToString(digest[:])
	var publication []byte
	var participants []map[string]string
	var unhealthy atomic.Bool
	ready := make(chan struct{})
	const chainAPI = "/chain-api/productscience/inference/inference/"
	for index := 0; index < 2; index++ {
		id, key := strings.Repeat(fmt.Sprint(index+1), 40), fmt.Sprintf("key-%d", index)
		var height atomic.Int64
		var peer string
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			<-ready
			switch path := r.URL.Path; {
			case path == "/fixture/bootstrap.json":
				w.Write(publication)
			case path == "/chain-rpc/status":
				fmt.Fprintf(w, `{"result":{"node_info":{"id":%q,"network":"fixture","listen_addr":%q},"sync_info":{"catching_up":false,"latest_block_height":%q},"validator_info":{"pub_key":{"value":%q}}}}`, id, peer, fmt.Sprint(100+height.Add(1)), key)
			case path == "/chain-rpc/genesis":
				fmt.Fprint(w, `{"result":{"genesis":`+genesis+`}}`)
			case path == "/v1/participants":
				if unhealthy.Load() {
					http.Error(w, "unavailable", 503)
					return
				}
				fmt.Fprint(w, `{"participants":[]}`)
			case path == chainAPI+"participant":
				json.NewEncoder(w).Encode(map[string]any{"participant": participants, "pagination": map[string]any{"next_key": nil}})
			case path == chainAPI+"epoch_info":
				fmt.Fprint(w, `{"latest_epoch":{"index":"10"}}`)
			case strings.HasPrefix(path, chainAPI+"epoch_group_data/"):
				fmt.Fprintf(w, `{"epoch_group_data":{"epoch_index":%q,"validation_weights":[{"member_address":"account-0","weight":"1"},{"member_address":"account-1","weight":"1"}]}}`, strings.TrimPrefix(path, chainAPI+"epoch_group_data/"))
			default:
				http.NotFound(w, r)
			}
		}))
		defer server.Close()
		origin := server.URL
		if index == 1 {
			origin = strings.Replace(origin, "127.0.0.1", "localhost", 1)
		}
		peer = "tcp://" + server.Listener.Addr().String()
		doc.Seeds = append(doc.Seeds, bootstrap.Seed{NodeID: id, RPC: origin + "/chain-rpc", API: origin, P2P: peer})
		participants = append(participants, map[string]string{"address": fmt.Sprintf("account-%d", index), "inference_url": origin, "validator_key": key, "status": "ACTIVE"})
	}
	publication, _ = json.Marshal(doc)
	publication = bytes.ReplaceAll(publication, []byte(`"brokers":null`), []byte(`"brokers":[]`))
	close(ready)
	run := func(want int, args ...string) bootstrap.Report {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, binary, args...)
		command.Dir = workspace
		command.Env = []string{"HOME=" + home, "PATH=" + filepath.Join(workspace, "no-tools")}
		if runtime.GOOS == "windows" {
			command.Env = append(command.Env, "SYSTEMROOT="+os.Getenv("SYSTEMROOT"))
		}
		var stdout, stderr bytes.Buffer
		command.Stdout, command.Stderr = &stdout, &stderr
		err := command.Run()
		code := 0
		if err != nil {
			if exit, ok := err.(*exec.ExitError); ok {
				code = exit.ExitCode()
			} else {
				t.Fatal(err)
			}
		}
		if code != want {
			t.Fatalf("exit=%d wanted=%d stdout=%s stderr=%s", code, want, stdout.Bytes(), stderr.Bytes())
		}
		var report bootstrap.Report
		if err := json.Unmarshal(stdout.Bytes(), &report); err != nil {
			t.Fatalf("report: %v %s", err, stdout.Bytes())
		}
		return report
	}
	update := []string{"bootstrap", "update", "fixture", outputDir, "--base-url", doc.Seeds[0].API, "--observation-window", "1ms", "--json"}
	if report := run(0, update...); !report.Changed || !report.Results[0].OK {
		t.Fatalf("creation report: %+v", report)
	}
	beforeJSON, err := os.ReadFile(filepath.Join(outputDir, "fixture.json"))
	if err != nil {
		t.Fatal(err)
	}
	beforeENV, err := os.ReadFile(filepath.Join(outputDir, "fixture.env"))
	if err != nil {
		t.Fatal(err)
	}
	if report := run(0, update...); report.Changed {
		t.Fatal("repeat changed files")
	}
	validate := []string{"bootstrap", "validate", "fixture", "--path", outputDir, "--observation-window", "1ms", "--json"}
	run(0, validate...)
	unhealthy.Store(true)
	run(1, validate...)
	if report := run(1, update...); report.Changed {
		t.Fatal("failed update wrote files")
	}
	afterJSON, _ := os.ReadFile(filepath.Join(outputDir, "fixture.json"))
	afterENV, _ := os.ReadFile(filepath.Join(outputDir, "fixture.env"))
	if !bytes.Equal(beforeJSON, afterJSON) || !bytes.Equal(beforeENV, afterENV) {
		t.Fatal("failure changed output")
	}
	entries, err := os.ReadDir(home)
	if err != nil || len(entries) != 0 {
		t.Fatal("installed command wrote HOME")
	}
}
