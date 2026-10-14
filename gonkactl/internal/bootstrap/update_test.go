package bootstrap

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type updateFixture struct {
	discovery        discoveryFixture
	published        []byte
	software         Software
	manifest, config string
	p2p              map[string]string
	height           int
	badRuntime       bool
	badImages        bool
	runtimeReads     int
}

func (f *updateFixture) RoundTrip(request *http.Request) (*http.Response, error) {
	body := ""
	switch path := request.URL.Path; {
	case path == "/gonka-devnet-community/bootstrap.json":
		body = string(f.published)
	case path == "/v2/test/manifests/"+digestOf(f.manifest):
		if f.badImages {
			return &http.Response{StatusCode: 404, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("missing image"))}, nil
		}
		body = f.manifest
	case path == "/v2/test/blobs/"+digestOf(f.config):
		body = f.config
	case path == "/v1/participants":
		f.runtimeReads++
		return &http.Response{StatusCode: 503, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("unhealthy application"))}, nil
	case path == "/v1/versions":
		f.runtimeReads++
		node, api := f.software.Components["node"], f.software.Components["api"]
		if f.badRuntime && request.URL.Hostname() == "b.test" {
			api.Commit = strings.Repeat("0", 40)
		}
		raw, _ := json.Marshal(map[string]Component{"node_version": node, "api_version": api})
		body = string(raw)
	case path == "/chain-rpc/abci_info":
		f.runtimeReads++
		body = fmt.Sprintf(`{"result":{"response":{"version":%q}}}`, f.software.Components["node"].Version)
	default:
		response, err := f.discovery.RoundTrip(request)
		if err != nil {
			return nil, err
		}
		raw, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			return nil, err
		}
		body = string(raw)
		if path == "/chain-rpc/status" {
			f.height++
			body = strings.ReplaceAll(body, `"100"`, fmt.Sprintf(`"%d"`, 100+f.height))
			body = strings.ReplaceAll(body, "tcp://"+request.URL.Hostname()+":5000", f.p2p[request.URL.Hostname()])
		}
	}
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
}

func TestUpdateCreatesRefreshesAndPreservesPair(t *testing.T) {
	f := &updateFixture{p2p: map[string]string{}, config: `{"os":"linux","architecture":"amd64"}`}
	f.manifest = fmt.Sprintf(`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":%q}}`, digestOf(f.config))
	doc := discoveryDocument(t)
	if err := DecodeJSON(doc.Software, &f.software); err != nil {
		t.Fatal(err)
	}
	for role, component := range f.software.Components {
		component.Image = "registry.test/test@" + digestOf(f.manifest)
		f.software.Components[role] = component
	}
	doc.Software, _ = json.Marshal(f.software)
	for index, host := range []string{"a.test", "b.test", "c.test"} {
		server := httptest.NewServer(http.NotFoundHandler())
		defer server.Close()
		f.p2p[host] = "tcp://" + server.Listener.Addr().String()
		doc.Seeds[index].P2P = f.p2p[host]
	}
	f.published, _ = json.Marshal(doc)
	directory := t.TempDir()
	transport := NewTransport()
	transport.Client.Transport = f
	transport.RetryDelay = 0
	options := UpdateOptions{ChainID: doc.ChainID, Directory: directory, BaseURL: "https://publication.test"}
	for _, mode := range []string{"create", "noop", "repair-env", "runtime-drift", "image-failure", "no-software"} {
		t.Run(mode, func(t *testing.T) {
			if mode == "no-software" {
				doc.Software = nil
				f.published, _ = json.Marshal(doc)
				directory = t.TempDir()
				options.Directory = directory
			}
			if mode == "repair-env" {
				if err := os.WriteFile(filepath.Join(directory, doc.ChainID+".env"), []byte("stale"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			f.badRuntime = mode == "runtime-drift"
			f.badImages = mode == "image-failure"
			beforeJSON, _ := os.ReadFile(filepath.Join(directory, doc.ChainID+".json"))
			beforeENV, _ := os.ReadFile(filepath.Join(directory, doc.ChainID+".env"))
			report, err := transport.Update(context.Background(), options)
			if err != nil || len(report.Results) != 1 || report.Results[0].OK == f.badImages {
				t.Fatalf("report=%+v err=%v", report, err)
			}
			if report.Changed != (mode == "create" || mode == "repair-env" || mode == "no-software") {
				t.Fatalf("wrong changed flag: %+v", report)
			}
			raw, env, err := readPair(directory, doc.ChainID)
			if err != nil {
				t.Fatal(err)
			}
			if mode == "noop" || mode == "runtime-drift" || mode == "image-failure" {
				if !bytes.Equal(raw, beforeJSON) || !bytes.Equal(env, beforeENV) {
					t.Fatal("unchanged/failed update changed output bytes")
				}
			}
			parsed, err := Parse(raw, nil)
			if f.runtimeReads != 0 {
				t.Fatal("bootstrap update queried runtime versions")
			}
			if err != nil || len(parsed.Seeds) != 2 || !bytes.Equal(env, parsed.ENV()) {
				t.Fatalf("invalid output: %v", err)
			}
		})
	}
}
