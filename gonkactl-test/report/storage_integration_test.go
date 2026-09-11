package report

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const storageIntegrationEnv = "GONKACTL_TEST_STORAGE_INTEGRATION"

// TestStoragePrefixIntegration qualifies the pinned Storage image behind the
// production /report/ prefix. It is opt-in because it owns a Docker container
// and persists SQLite/files/logs under the explicitly supplied data root.
func TestStoragePrefixIntegration(t *testing.T) {
	if os.Getenv(storageIntegrationEnv) != "1" {
		t.Skip("set GONKACTL_TEST_STORAGE_INTEGRATION=1 for the owned Storage fixture")
	}
	dataRoot := os.Getenv("GONKACTL_TEST_STORAGE_DATA_ROOT")
	if dataRoot == "" {
		t.Fatal("GONKACTL_TEST_STORAGE_DATA_ROOT is required")
	}
	absRoot, err := filepath.Abs(dataRoot)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"/tmp", "/var/tmp"} {
		if absRoot == forbidden || strings.HasPrefix(absRoot, forbidden+string(filepath.Separator)) {
			t.Fatalf("Storage data root must not use system temporary storage: %s", absRoot)
		}
	}
	if err := os.MkdirAll(absRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	bundleRoot := os.Getenv("GONKACTL_TEST_ALLURE_BUNDLE")
	if bundleRoot == "" {
		t.Fatal("GONKACTL_TEST_ALLURE_BUNDLE is required; synthetic HTML is not accepted")
	}
	bundleRoot, err = filepath.Abs(bundleRoot)
	if err != nil {
		t.Fatal(err)
	}

	containerName := fmt.Sprintf("gonkactl-test-m0-storage-%d", os.Getpid())
	containerLog := filepath.Join(absRoot, "storage-container.log")
	defer func() {
		logs := exec.Command("docker", "logs", "--timestamps", containerName)
		output, _ := logs.CombinedOutput()
		if err := os.WriteFile(containerLog, output, 0o600); err != nil {
			t.Errorf("persist Storage logs: %v", err)
		}
		_ = exec.Command("docker", "rm", "--force", containerName).Run()
	}()

	bootstrapToken := "m0-storage-bootstrap-only"
	secret := "m0-storage-secret-only"
	if output, err := exec.Command(
		"docker", "run", "--detach", "--rm", "--name", containerName,
		"--label", "gonkactl-test.owner=m0-storage-prefix",
		"--env", "ACCESS_TOKEN="+bootstrapToken,
		"--env", "SECRET="+secret,
		"--env", "DATABASE_PATH=/data/reports.sqlite",
		"--env", "DATA_DIR=/data",
		"--env", "HOST=0.0.0.0",
		"--env", "PORT=3000",
		"--volume", absRoot+":/data",
		"--publish", "127.0.0.1::3000",
		"allure/allure-report-storage:v1.0.1",
	).CombinedOutput(); err != nil {
		t.Fatalf("start owned Storage fixture: %v: %s", err, output)
	}
	portOutput, err := exec.Command("docker", "port", containerName, "3000/tcp").Output()
	if err != nil {
		t.Fatalf("discover owned Storage port: %v", err)
	}
	storageURL := "http://" + strings.TrimSpace(string(portOutput))
	storageURL = strings.Replace(storageURL, "http://0.0.0.0:", "http://127.0.0.1:", 1)
	if err := waitForStorage(storageURL + "/api/ping"); err != nil {
		t.Fatal(err)
	}
	upstream, err := url.Parse(storageURL)
	if err != nil {
		t.Fatal(err)
	}

	httpProxy := httptest.NewUnstartedServer(nil)
	httpProxy.Config.Handler = NewStoragePrefixProxy(upstream, "/report/", "http://"+httpProxy.Listener.Addr().String(), secret)
	httpProxy.Start()
	defer httpProxy.Close()
	tlsProxy := httptest.NewUnstartedServer(nil)
	tlsProxy.Config.Handler = NewStoragePrefixProxy(upstream, "/report/", "https://"+tlsProxy.Listener.Addr().String(), secret)
	tlsProxy.StartTLS()
	defer tlsProxy.Close()

	token := issueStorageToken(t, httpProxy.Client(), httpProxy.URL, bootstrapToken)
	reportID := fmt.Sprintf("m0-storage-prefix-%d", os.Getpid())
	createStorageReport(t, httpProxy.Client(), httpProxy.URL, token, reportID)
	uploaded := uploadAllureBundle(t, httpProxy.Client(), httpProxy.URL+"/report/api/reports/"+reportID+"/upload", token, bundleRoot)
	completeStorageReport(t, httpProxy.Client(), httpProxy.URL, token, reportID)
	assertStorageHistory(t, httpProxy.Client(), httpProxy.URL, token)

	assertStoragePrefixSurface(t, httpProxy.Client(), httpProxy.URL, reportID, uploaded)
	assertStoragePrefixSurface(t, tlsProxy.Client(), tlsProxy.URL, reportID, uploaded)
	assertStorageBrowser(t, httpProxy.URL+"/report/"+reportID+"/index.html", bundleRoot, absRoot, "http")
	assertStorageBrowser(t, tlsProxy.URL+"/report/"+reportID+"/index.html", bundleRoot, absRoot, "https")
	issueStorageToken(t, tlsProxy.Client(), tlsProxy.URL, bootstrapToken)
	if err := writeStorageReceipt(filepath.Join(absRoot, "receipt.json"), reportID, storageURL, httpProxy.URL, tlsProxy.URL); err != nil {
		t.Fatal(err)
	}
}

func waitForStorage(endpoint string) error {
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		response, err := http.Get(endpoint)
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("Storage did not become ready at %s", endpoint)
}

func issueStorageToken(t *testing.T, client *http.Client, proxyURL, bootstrapToken string) string {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, proxyURL+"/report/api/token", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+bootstrapToken)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("issue Storage token status=%d body=%s", response.StatusCode, body)
	}
	var payload struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.AccessToken == "" {
		t.Fatalf("Storage token response omitted access_token: %s", body)
	}
	if tokenURL := storageTokenURL(t, payload.AccessToken); tokenURL != proxyURL+"/report" {
		t.Fatalf("Storage token URL=%q, want prefix-aware %q", tokenURL, proxyURL+"/report")
	}
	return payload.AccessToken
}

func storageTokenURL(t *testing.T, token string) string {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != "ars1" {
		t.Fatalf("unexpected Storage access token format")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("decode Storage access token: %v", err)
	}
	var claims struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatalf("decode Storage access token claims: %v", err)
	}
	return claims.URL
}

func createStorageReport(t *testing.T, client *http.Client, proxyURL, token, reportID string) {
	t.Helper()
	payload := fmt.Sprintf(`{"repo":"gonkactl-test/lab-mock/m0/v1","branch":"feat/gonkactl-test-m0","reportUuid":%q,"name":"M0 prefix smoke"}`, reportID)
	response := storageRequest(t, client, http.MethodPost, proxyURL+"/report/api/reports", token, "application/json", strings.NewReader(payload))
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `"url":"/report/`+reportID+`"`) {
		t.Fatalf("create report status=%d body=%s", response.StatusCode, body)
	}
}

func uploadStorageFile(t *testing.T, client *http.Client, endpoint, token, name string, contents []byte) {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("filename", name); err != nil {
		t.Fatal(err)
	}
	part, err := writer.CreateFormFile("file", name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(contents); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	response := storageRequest(t, client, http.MethodPost, endpoint, token, writer.FormDataContentType(), &body)
	responseBody, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("upload %s status=%d body=%s", name, response.StatusCode, responseBody)
	}
}

func completeStorageReport(t *testing.T, client *http.Client, proxyURL, token, reportID string) {
	t.Helper()
	response := storageRequest(t, client, http.MethodPost, proxyURL+"/report/api/reports/"+reportID+"/complete", token, "application/json", strings.NewReader(`{"historyPoint":{"buildOrder":1,"reportName":"M0 prefix smoke"}}`))
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `"status":"completed"`) {
		t.Fatalf("complete report status=%d body=%s", response.StatusCode, body)
	}
}

func uploadAllureBundle(t *testing.T, client *http.Client, endpoint, token, root string) []string {
	t.Helper()
	var uploaded []string
	hasIndex, hasAsset := false, false
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		uploadStorageFile(t, client, endpoint, token, rel, body)
		uploaded = append(uploaded, rel)
		if rel == "index.html" {
			hasIndex = true
		}
		if strings.HasSuffix(rel, ".js") || strings.HasSuffix(rel, ".css") {
			hasAsset = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasIndex || !hasAsset {
		t.Fatalf("generated Allure bundle incomplete: index=%v asset=%v", hasIndex, hasAsset)
	}
	return uploaded
}

func assertStoragePrefixSurface(t *testing.T, client *http.Client, proxyURL, reportID string, uploaded []string) {
	t.Helper()
	paths := []string{"/report/" + reportID + "/index.html"}
	for _, rel := range uploaded {
		if strings.HasSuffix(rel, ".js") || strings.HasSuffix(rel, ".css") {
			paths = append(paths, "/report/"+reportID+"/"+rel)
			break
		}
	}
	for _, path := range paths {
		response, err := client.Get(proxyURL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		body, _ := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusOK || len(body) == 0 {
			t.Fatalf("GET %s status=%d body=%q", path, response.StatusCode, body)
		}
	}
	request, err := http.NewRequest(http.MethodGet, proxyURL+"/report/"+reportID+"/deep/reload", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Accept", "text/html")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "gonkactl-test M0 authentic event qualification") {
		t.Fatalf("deep reload status=%d body=%q", response.StatusCode, body)
	}
	response, err = client.Get(proxyURL + "/report/reports/tree?repo=gonkactl-test/lab-mock/m0/v1")
	if err != nil {
		t.Fatal(err)
	}
	body, _ = io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `href="/report/`+reportID+`"`) {
		t.Fatalf("tree status=%d body=%q", response.StatusCode, body)
	}
	noRedirect := *client
	noRedirect.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	response, err = noRedirect.Get(proxyURL + "/report/" + reportID)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusFound || response.Header.Get("Location") != "/report/"+reportID+"/index.html" {
		t.Fatalf("report redirect status=%d location=%q", response.StatusCode, response.Header.Get("Location"))
	}
}

func assertStorageBrowser(t *testing.T, endpoint, bundleRoot, dataRoot, scheme string) {
	t.Helper()
	profile := filepath.Join(dataRoot, fmt.Sprintf("browser-%s-profiles/%d", scheme, time.Now().UnixNano()))
	if err := os.MkdirAll(profile, 0o700); err != nil {
		t.Fatal(err)
	}
	evidence := filepath.Join(dataRoot, "browser-"+scheme)
	args := []string{"browser-check.mjs", "--url", endpoint, "--bundle", bundleRoot, "--evidence-dir", evidence, "--profile", profile}
	if scheme == "https" {
		args = append(args, "--ignore-certificate-errors")
	}
	cmd := exec.Command("node", args...)
	cmd.Env = browserEnvironment(t, dataRoot)
	out, err := cmd.CombinedOutput()
	if writeErr := os.WriteFile(filepath.Join(dataRoot, "browser-"+scheme+"-driver.log"), out, 0o600); writeErr != nil {
		t.Fatalf("persist Storage browser driver output: %v", writeErr)
	}
	if err != nil {
		t.Fatalf("Storage browser CDP qualification failed for %s: %v: %s", endpoint, err, out)
	}
}

func browserEnvironment(t *testing.T, dataRoot string) []string {
	allowed := map[string]bool{
		"HOME": true, "PATH": true, "XDG_RUNTIME_DIR": true,
		"LANG": true, "LC_ALL": true, "TZ": true,
	}
	var environment []string
	for _, entry := range os.Environ() {
		name, _, found := strings.Cut(entry, "=")
		if found && allowed[name] {
			environment = append(environment, entry)
		}
	}
	home := filepath.Join(dataRoot, "browser-home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatalf("create browser persistent home: %v", err)
	}
	if err := os.Chmod(home, 0o700); err != nil {
		t.Fatalf("restrict browser persistent home: %v", err)
	}
	environment = append(environment, "HOME="+home)
	return environment
}

func assertStorageHistory(t *testing.T, client *http.Client, proxyURL, token string) {
	t.Helper()
	response := storageRequest(t, client, http.MethodGet, proxyURL+"/report/api/history?repo=gonkactl-test/lab-mock/m0/v1&branch=feat/gonkactl-test-m0", token, "", nil)
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `"history"`) {
		t.Fatalf("history status=%d body=%s", response.StatusCode, body)
	}
}

func storageRequest(t *testing.T, client *http.Client, method, endpoint, token, contentType string, body io.Reader) *http.Response {
	t.Helper()
	request, err := http.NewRequest(method, endpoint, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func writeStorageReceipt(path, reportID, storageURL, httpURL, httpsURL string) error {
	payload, err := json.MarshalIndent(map[string]string{
		"report_id":   reportID,
		"storage_url": storageURL,
		"http_url":    httpURL + "/report/",
		"https_url":   httpsURL + "/report/",
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(payload, '\n'), 0o600)
}
