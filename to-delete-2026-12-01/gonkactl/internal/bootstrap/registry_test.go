package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func digestOf(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func TestRegistryManifestPlatformAndAuthorization(t *testing.T) {
	for _, mode := range []string{"single", "index", "auth", "missing", "digest-mismatch", "wrong-platform", "missing-platform", "bad-token", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			config := `{"os":"linux","architecture":"amd64"}`
			if mode == "wrong-platform" {
				config = `{"os":"linux","architecture":"arm64"}`
			}
			manifest := fmt.Sprintf(`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":%q}}`, digestOf(config))
			index := fmt.Sprintf(`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":%q,"platform":{"os":"linux","architecture":"amd64"}}]}`, digestOf(manifest))
			if mode == "missing-platform" {
				index = strings.ReplaceAll(index, "amd64", "arm64")
			}
			objects := map[string]string{"manifests/" + digestOf(manifest): manifest, "manifests/" + digestOf(index): index, "blobs/" + digestOf(config): config}
			var server *httptest.Server
			server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/token" {
					if r.URL.Query().Get("scope") != "repository:library/test:pull" || r.Header.Get("Authorization") != "" {
						t.Error("unsafe token request")
					}
					if mode == "bad-token" {
						fmt.Fprint(w, `{"token":"one","access_token":"two"}`)
					} else {
						fmt.Fprint(w, `{"token":"synthetic"}`)
					}
					return
				}
				if (mode == "auth" || mode == "bad-token") && r.Header.Get("Authorization") != "Bearer synthetic" {
					w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="fixture",scope="repository:other:push"`, server.URL))
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				if mode == "redirect" {
					http.Redirect(w, r, "/redirected", http.StatusTemporaryRedirect)
					return
				}
				if mode == "missing" {
					http.NotFound(w, r)
					return
				}
				if mode == "digest-mismatch" {
					fmt.Fprint(w, `{}`)
					return
				}
				body, exists := objects[strings.TrimPrefix(r.URL.Path, "/v2/library/test/")]
				if !exists {
					t.Errorf("unexpected registry request %s", r.URL.Path)
					http.NotFound(w, r)
					return
				}
				fmt.Fprint(w, body)
			}))
			defer server.Close()
			transport := NewTransport()
			transport.Client = server.Client()
			transport.RetryDelay = 0
			digest := digestOf(manifest)
			if mode == "index" || mode == "missing-platform" {
				digest = digestOf(index)
			}
			err := transport.CheckImage(context.Background(), strings.TrimPrefix(server.URL, "https://")+"/library/test@"+digest, "linux/amd64")
			wantSuccess := mode == "single" || mode == "index" || mode == "auth"
			if (err == nil) != wantSuccess {
				t.Fatalf("error=%v success=%v", err, wantSuccess)
			}
		})
	}
}

func TestAnonymousChallengeBoundaries(t *testing.T) {
	ref := imageReference{origin: "https://ghcr.io", repository: "owner/name"}
	for _, challenge := range []string{`Basic realm="registry"`, `Bearer realm="http://ghcr.io/token"`, `Bearer realm="https://other.test/token"`, `Bearer realm="https://ghcr.io/token",realm="https://ghcr.io/other"`, `Bearer realm="https://ghcr.io/token" junk`} {
		if _, err := challengeURL(challenge, ref); err == nil {
			t.Fatalf("accepted %s", challenge)
		}
	}
	for _, image := range []string{"postgres:latest", "host.test/x@sha256:bad", "host.test/../x@sha256:" + strings.Repeat("a", 64)} {
		if _, err := parseImage(image); err == nil {
			t.Fatalf("accepted %s", image)
		}
	}
	ref, err := parseImage("postgres:16@sha256:" + strings.Repeat("a", 64))
	if err != nil || ref.origin != "https://registry-1.docker.io" || ref.repository != "library/postgres" {
		t.Fatalf("reference=%+v error=%v", ref, err)
	}
}

func TestImagesKeepEveryRoleAndDeduplicate(t *testing.T) {
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests++; http.NotFound(w, r) }))
	defer server.Close()
	image := strings.TrimPrefix(server.URL, "https://") + "/test@sha256:" + strings.Repeat("a", 64)
	software, _ := json.Marshal(map[string]any{"platform": "linux/amd64", "components": map[string]any{"api": map[string]string{"image": image}, "node": map[string]string{"image": image}}})
	transport := NewTransport()
	transport.Client = server.Client()
	result := Result{}
	transport.CheckImages(context.Background(), Document{Software: software}, &result)
	if requests != 1 || len(result.Checks) != 2 || result.Checks[0].OK || result.Checks[1].OK {
		t.Fatalf("requests=%d result=%+v", requests, result)
	}
	if result.Checks[0].Stage != "image:api" || result.Checks[1].Stage != "image:node" {
		t.Fatal("unstable role ordering")
	}
}

func TestConfigCDNRedirectStripsRegistryToken(t *testing.T) {
	config := `{"os":"linux","architecture":"amd64"}`
	cdn := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			t.Error("registry token leaked to CDN")
		}
		fmt.Fprint(w, config)
	}))
	defer cdn.Close()
	manifest := fmt.Sprintf(`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":%q}}`, digestOf(config))
	var registry *httptest.Server
	registry = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			fmt.Fprint(w, `{"token":"registry-only"}`)
			return
		}
		if r.Header.Get("Authorization") != "Bearer registry-only" {
			w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="fixture"`, registry.URL))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if strings.Contains(r.URL.Path, "/blobs/") {
			http.Redirect(w, r, cdn.URL+"/config?signature=opaque", http.StatusTemporaryRedirect)
			return
		}
		fmt.Fprint(w, manifest)
	}))
	defer registry.Close()
	transport := NewTransport()
	transport.Client = registry.Client()
	image := strings.TrimPrefix(registry.URL, "https://") + "/test@" + digestOf(manifest)
	if err := transport.CheckImage(context.Background(), image, "linux/amd64"); err != nil {
		t.Fatal(err)
	}
}
