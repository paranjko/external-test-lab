package report

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

const testStorageSecret = "test-storage-secret"

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
