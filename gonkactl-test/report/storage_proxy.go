package report

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// NewStoragePrefixProxy exposes an upstream Storage instance below basePath
// at the configured public origin. storageSecret is the Storage SECRET: it is
// needed only to re-sign the URL claim embedded in a newly issued ars1 token.
// An empty secret fails token issuance closed rather than exposing a token
// whose root URL bypasses the prefix.
func NewStoragePrefixProxy(upstream *url.URL, basePath, publicOrigin, storageSecret string) http.Handler {
	basePath = "/" + strings.Trim(basePath, "/")
	publicOrigin = strings.TrimRight(publicOrigin, "/")
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != basePath && !strings.HasPrefix(request.URL.Path, basePath+"/") {
			http.NotFound(writer, request)
			return
		}
		outbound := request.Clone(request.Context())
		outbound.URL.Scheme = upstream.Scheme
		outbound.URL.Host = upstream.Host
		outbound.URL.Path = strings.TrimPrefix(request.URL.Path, basePath)
		if outbound.URL.Path == "" {
			outbound.URL.Path = "/"
		}
		outbound.URL.RawPath = ""
		// Storage embeds the request origin in the signed access token. Preserve
		// the authority presented to the proxy while routing the connection to
		// the upstream host.
		outbound.Host = request.Host
		outbound.RequestURI = ""
		response, err := http.DefaultTransport.RoundTrip(outbound)
		if err != nil {
			http.Error(writer, "storage upstream unavailable", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		body, err := rewriteStorageResponse(response, basePath, publicOrigin)
		if err != nil {
			http.Error(writer, "storage response transform failed", http.StatusBadGateway)
			return
		}
		if request.URL.Path == basePath+"/api/token" && response.StatusCode >= http.StatusOK && response.StatusCode < http.StatusMultipleChoices {
			body, err = rewriteStorageAccessToken(body, storageSecret, publicOrigin+basePath)
			if err != nil {
				http.Error(writer, "storage token transform failed", http.StatusBadGateway)
				return
			}
		}
		copyStorageHeaders(writer.Header(), response.Header)
		writer.WriteHeader(response.StatusCode)
		_, _ = writer.Write(body)
	})
}

type storageAccessTokenClaims struct {
	AccessToken string `json:"accessToken"`
	URL         string `json:"url"`
}

func rewriteStorageAccessToken(body []byte, secret, publicURL string) ([]byte, error) {
	if secret == "" {
		return nil, fmt.Errorf("Storage signing secret is required for prefix token rewriting")
	}
	var response struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, fmt.Errorf("decode Storage token response: %w", err)
	}
	parts := strings.Split(response.AccessToken, ".")
	if len(parts) != 3 || parts[0] != "ars1" {
		return nil, fmt.Errorf("unexpected Storage access token format")
	}
	expectedSignature := storageTokenSignature(secret, parts[0]+"."+parts[1])
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !hmac.Equal(signature, expectedSignature) {
		return nil, fmt.Errorf("Storage access token signature is invalid")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode Storage access token payload: %w", err)
	}
	var claims storageAccessTokenClaims
	if err := json.Unmarshal(payload, &claims); err != nil || claims.AccessToken == "" || claims.URL == "" {
		return nil, fmt.Errorf("Storage access token claims are invalid")
	}
	claims.URL = publicURL
	rewrittenPayload, err := json.Marshal(claims)
	if err != nil {
		return nil, fmt.Errorf("encode Storage access token payload: %w", err)
	}
	encodedPayload := base64.RawURLEncoding.EncodeToString(rewrittenPayload)
	signedData := "ars1." + encodedPayload
	response.AccessToken = signedData + "." + base64.RawURLEncoding.EncodeToString(storageTokenSignature(secret, signedData))
	rewritten, err := json.Marshal(response)
	if err != nil {
		return nil, fmt.Errorf("encode Storage token response: %w", err)
	}
	return rewritten, nil
}

func storageTokenSignature(secret, signedData string) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signedData))
	return mac.Sum(nil)
}

func copyStorageHeaders(destination, source http.Header) {
	for name, values := range source {
		for _, value := range values {
			destination.Add(name, value)
		}
	}
}

func rewriteStorageResponse(response *http.Response, prefix, origin string) ([]byte, error) {
	if location := response.Header.Get("Location"); strings.HasPrefix(location, "/") {
		response.Header.Set("Location", prefix+location)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, err
	}
	contentType := response.Header.Get("Content-Type")
	if strings.HasPrefix(contentType, "application/json") {
		body, err = rewriteStorageAPIURL(body, origin, prefix)
		if err != nil {
			return nil, err
		}
	} else if strings.HasPrefix(contentType, "text/html") {
		body = []byte(strings.ReplaceAll(strings.ReplaceAll(string(body), `href="/`, `href="`+prefix+`/`), `src="/`, `src="`+prefix+`/`))
	}
	response.Header.Del("Content-Length")
	response.Header.Del("Content-Encoding")
	return body, nil
}

func rewriteStorageAPIURL(body []byte, origin, prefix string) ([]byte, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, fmt.Errorf("decode Storage JSON response: %w", err)
	}
	urlValue, ok := response["url"]
	if !ok {
		return body, nil
	}
	var target string
	if err := json.Unmarshal(urlValue, &target); err != nil {
		return nil, fmt.Errorf("decode Storage response url: %w", err)
	}
	if strings.HasPrefix(target, "/") {
		target = prefix + target
	} else {
		target = origin + prefix
	}
	rewrittenURL, err := json.Marshal(target)
	if err != nil {
		return nil, fmt.Errorf("encode rewritten Storage response url: %w", err)
	}
	response["url"] = rewrittenURL
	rewritten, err := json.Marshal(response)
	if err != nil {
		return nil, fmt.Errorf("encode rewritten Storage JSON response: %w", err)
	}
	return rewritten, nil
}
