package report

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestRewriteStorageAPIURLRewritesArraysAndGzipResponses(t *testing.T) {
	plain := []byte(`[{"url":"/first"},{"nested":[{"url":"https://upstream/report"}]}]`)
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	_, _ = writer.Write(plain)
	_ = writer.Close()
	response := &http.Response{Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(compressed.Bytes()))}
	response.Header.Set("Content-Type", "application/json")
	response.Header.Set("Content-Encoding", "gzip")
	got, err := rewriteStorageResponse(response, "/report", "https://public.example")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `[{"url":"/report/first"},{"nested":[{"url":"https://public.example/report"}]}]` {
		t.Fatalf("rewritten response=%s", got)
	}
	if response.Header.Get("Content-Encoding") != "" {
		t.Fatal("compressed response header was retained")
	}
}

const testStorageSecret = "test-storage-secret"

func TestStoragePrefixProxyCompressedContent(t *testing.T) {
	for _, tc := range []struct{ name, contentType, plain, want string }{
		{"html", "text/html", `<script src="/app.js"></script>`, `<script src="/report/app.js"></script>`},
		{"javascript", "application/javascript", "alert('ok')", "alert('ok')"},
		{"css", "text/css", "body{}", "body{}"},
		{"binary", "application/octet-stream", "\x00\xff\x01", "\x00\xff\x01"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Accept-Encoding") != "gzip" {
					t.Error("explicit browser encoding was not forwarded")
				}
				w.Header().Set("Content-Type", tc.contentType)
				w.Header().Set("Content-Encoding", "gzip")
				compressed := gzip.NewWriter(w)
				_, _ = io.WriteString(compressed, tc.plain)
				_ = compressed.Close()
			}))
			defer upstream.Close()
			upstreamURL, _ := url.Parse(upstream.URL)
			proxy := httptest.NewServer(NewStoragePrefixProxy(upstreamURL, "/report", "https://public.example", testStorageSecret))
			defer proxy.Close()
			transport := &http.Transport{DisableCompression: true}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport}
			request, _ := http.NewRequest(http.MethodGet, proxy.URL+"/report/asset", nil)
			request.Header.Set("Accept-Encoding", "gzip")
			response, err := client.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, err := io.ReadAll(response.Body)
			if err != nil || response.StatusCode != http.StatusOK || string(body) != tc.want || response.Header.Get("Content-Encoding") != "" {
				t.Fatalf("status=%d encoding=%q body=%q error=%v", response.StatusCode, response.Header.Get("Content-Encoding"), body, err)
			}
		})
	}
}

func TestRewriteStorageEncodingBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name, contentType, encoding, body string
		wantError                         bool
	}{
		{"invalid gzip html", "text/html", "gzip", "not gzip", true},
		{"invalid gzip asset", "application/octet-stream", "gzip", "not gzip", true},
		{"unsupported html", "text/html", "br", "opaque", true},
		{"unsupported json", "application/json", "br", "opaque", true},
		{"opaque asset", "application/octet-stream", "br", "opaque", false},
		{"identity asset", "text/css", "identity", "body{}", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := &http.Response{Header: make(http.Header), Body: io.NopCloser(strings.NewReader(tc.body))}
			response.Header.Set("Content-Type", tc.contentType)
			response.Header.Set("Content-Encoding", tc.encoding)
			body, err := rewriteStorageResponse(response, "/report", "https://public.example")
			if (err != nil) != tc.wantError {
				t.Fatalf("error=%v wantError=%v", err, tc.wantError)
			}
			if !tc.wantError && (string(body) != tc.body || response.Header.Get("Content-Encoding") != tc.encoding) {
				t.Fatalf("opaque response changed: body=%q encoding=%q", body, response.Header.Get("Content-Encoding"))
			}
		})
	}
}

func testStorageAccessToken(t *testing.T, url string) string {
	t.Helper()
	payload, err := json.Marshal(storageAccessTokenClaims{AccessToken: "opaque-upstream-credential", URL: url})
	if err != nil {
		t.Fatal(err)
	}
	signedData := "ars1." + base64.RawURLEncoding.EncodeToString(payload)
	return signedData + "." + base64.RawURLEncoding.EncodeToString(storageTokenSignature(testStorageSecret, signedData))
}

func TestStoragePrefixProxyRewritesRootBoundStorageResponses(t *testing.T) {
	var upstreamPaths []string
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		upstreamPaths = append(upstreamPaths, request.URL.Path)
		switch request.URL.Path {
		case "/api/token":
			writer.Header().Set("Content-Type", "application/json")
			_, _ = writer.Write([]byte(`{"access_token":"` + testStorageAccessToken(t, "http://storage.internal") + `"}`))
		case "/api/reports":
			writer.Header().Set("Content-Type", "application/json")
			_, _ = writer.Write([]byte(`{"url":"/report-id"}`))
		case "/reports/tree":
			writer.Header().Set("Content-Type", "text/html")
			_, _ = writer.Write([]byte(`<a href="/report-id">report</a><script src="/assets/app.js"></script>`))
		default:
			_, _ = writer.Write([]byte("deep route"))
		}
	}))
	defer upstream.Close()
	upstreamURL, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httptest.NewUnstartedServer(nil)
	proxy.Config.Handler = NewStoragePrefixProxy(upstreamURL, "/report/", "http://"+proxy.Listener.Addr().String(), testStorageSecret)
	proxy.Start()
	defer proxy.Close()

	response, err := http.Get(proxy.URL + "/report/api/token")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	var tokenResponse struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &tokenResponse); err != nil {
		t.Fatal(err)
	}
	if got, want := storageTokenURL(t, tokenResponse.AccessToken), proxy.URL+"/report"; got != want {
		t.Fatalf("token URL=%q want %q", got, want)
	}

	response, err = http.Post(proxy.URL+"/report/api/reports", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	body, _ = io.ReadAll(response.Body)
	_ = response.Body.Close()
	if !strings.Contains(string(body), `"url":"/report/report-id"`) {
		t.Fatalf("report response %q", body)
	}

	response, err = http.Get(proxy.URL + "/report/reports/tree")
	if err != nil {
		t.Fatal(err)
	}
	body, _ = io.ReadAll(response.Body)
	_ = response.Body.Close()
	if got := string(body); !strings.Contains(got, `href="/report/report-id"`) || !strings.Contains(got, `src="/report/assets/app.js"`) {
		t.Fatalf("tree response %q", got)
	}
	if strings.Join(upstreamPaths, ",") != "/api/token,/api/reports,/reports/tree" {
		t.Fatalf("upstream paths %v", upstreamPaths)
	}

	response, err = http.Get(proxy.URL + "/api/ping")
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("unprefixed request status=%d", response.StatusCode)
	}
}

func TestStoragePrefixProxyPreservesHTTPSOrigin(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"access_token":"` + testStorageAccessToken(t, "http://storage.internal") + `"}`))
	}))
	defer upstream.Close()
	upstreamURL, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httptest.NewUnstartedServer(nil)
	proxy.Config.Handler = NewStoragePrefixProxy(upstreamURL, "/report", "https://"+proxy.Listener.Addr().String(), testStorageSecret)
	proxy.StartTLS()
	defer proxy.Close()

	response, err := proxy.Client().Get(proxy.URL + "/report/api/token")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	var tokenResponse struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &tokenResponse); err != nil {
		t.Fatal(err)
	}
	if got, want := storageTokenURL(t, tokenResponse.AccessToken), proxy.URL+"/report"; got != want {
		t.Fatalf("HTTPS token URL=%q want %q", got, want)
	}
}
