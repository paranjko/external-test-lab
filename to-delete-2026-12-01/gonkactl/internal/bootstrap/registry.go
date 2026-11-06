package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
)

const manifestAccept = "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
const registryLimit = 8 * 1024 * 1024

var imageDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var repositoryPath = regexp.MustCompile(`^[a-z0-9]+(?:[._-]+[a-z0-9]+)*(?:/[a-z0-9]+(?:[._-]+[a-z0-9]+)*)*$`)
var authParameter = regexp.MustCompile(`^([a-z]+)="([^"\r\n]*)"`)

type imageReference struct{ origin, repository, digest string }

func parseImage(image string) (imageReference, error) {
	name, digest, ok := strings.Cut(image, "@")
	if !ok || !imageDigest.MatchString(digest) {
		return imageReference{}, fmt.Errorf("image must have a pinned sha256 digest")
	}
	if colon := strings.LastIndex(name, ":"); colon > strings.LastIndex(name, "/") {
		name = name[:colon]
	}
	host, repository := "registry-1.docker.io", name
	first, rest, slash := strings.Cut(name, "/")
	if slash && (strings.ContainsAny(first, ".:") || first == "localhost") {
		host, repository = first, rest
	}
	if host == "docker.io" || host == "index.docker.io" {
		host = "registry-1.docker.io"
	}
	if host == "registry-1.docker.io" && !strings.Contains(repository, "/") {
		repository = "library/" + repository
	}
	if !repositoryPath.MatchString(repository) {
		return imageReference{}, fmt.Errorf("invalid image repository")
	}
	u, err := endpoint("https://"+host, "https")
	if err != nil || u.Path != "" {
		return imageReference{}, fmt.Errorf("invalid registry origin")
	}
	return imageReference{"https://" + host, repository, digest}, nil
}

// registryRequest never follows a redirect with Authorization attached. Only
// content-addressed config blobs may use bounded HTTPS CDN redirects; manifests
// and anonymous token challenges must be served directly by their authority.
func (t *Transport) registryRequest(ctx context.Context, address, token string, blob bool) ([]byte, http.Header, int, error) {
	if t.Client == nil || t.Attempts < 1 || t.Attempts > 3 || t.Timeout <= 0 {
		return nil, nil, 0, fmt.Errorf("invalid transport bounds")
	}
	client := *t.Client
	client.Timeout = t.Timeout
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	for redirects := 0; redirects <= 3; redirects++ {
		u, err := url.Parse(address)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
			return nil, nil, 0, fmt.Errorf("unsafe registry URL")
		}
		var body []byte
		var headers http.Header
		status := 0
		for attempt := 0; attempt < t.Attempts; attempt++ {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
			if err != nil {
				return nil, nil, 0, fmt.Errorf("invalid registry request")
			}
			req.Header.Set("Accept", manifestAccept)
			req.Header.Set("User-Agent", "gonkactl-bootstrap/1")
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			response, err := client.Do(req)
			if err == nil {
				status, headers = response.StatusCode, response.Header.Clone()
				body, err = io.ReadAll(io.LimitReader(response.Body, registryLimit+1))
				response.Body.Close()
				if len(body) > registryLimit {
					return nil, nil, 0, fmt.Errorf("registry response exceeds size limit")
				}
				if err == nil && status != 408 && status != 429 && status != 500 && status != 502 && status != 503 && status != 504 {
					break
				}
			}
			if ctx.Err() != nil {
				return nil, nil, 0, ctx.Err()
			}
			if attempt+1 == t.Attempts {
				return nil, nil, status, fmt.Errorf("registry unavailable (HTTP %d)", status)
			}
			if err := wait(ctx, t.RetryDelay); err != nil {
				return nil, nil, 0, err
			}
		}
		if status >= 300 && status < 400 {
			if !blob || redirects == 3 {
				return nil, nil, status, fmt.Errorf("registry redirect refused")
			}
			next, err := u.Parse(headers.Get("Location"))
			if err != nil {
				return nil, nil, status, fmt.Errorf("invalid registry redirect")
			}
			address, token = next.String(), ""
			continue
		}
		return body, headers, status, nil
	}
	return nil, nil, 0, fmt.Errorf("registry redirect limit exceeded")
}

func challengeURL(challenge string, ref imageReference) (string, error) {
	kind, rest, ok := strings.Cut(challenge, " ")
	if !ok || !strings.EqualFold(kind, "Bearer") {
		return "", fmt.Errorf("registry requires unsupported authentication")
	}
	parameters := map[string]string{}
	for rest = strings.TrimSpace(rest); rest != ""; {
		match := authParameter.FindStringSubmatch(rest)
		if match == nil {
			return "", fmt.Errorf("malformed registry authentication challenge")
		}
		if _, exists := parameters[match[1]]; exists {
			return "", fmt.Errorf("duplicate registry authentication parameter")
		}
		parameters[match[1]] = match[2]
		rest = strings.TrimSpace(rest[len(match[0]):])
		if rest == "" {
			break
		}
		if rest[0] != ',' {
			return "", fmt.Errorf("malformed registry authentication challenge")
		}
		rest = strings.TrimSpace(rest[1:])
	}
	realm, err := endpoint(parameters["realm"], "https")
	if err != nil {
		return "", fmt.Errorf("unsafe registry token realm")
	}
	origin, _ := url.Parse(ref.origin)
	if realm.Host != origin.Host && !(origin.Host == "registry-1.docker.io" && realm.Host == "auth.docker.io") {
		return "", fmt.Errorf("cross-origin token realm refused")
	}
	query := realm.Query()
	query.Set("service", parameters["service"])
	query.Set("scope", "repository:"+ref.repository+":pull")
	realm.RawQuery = query.Encode()
	return realm.String(), nil
}

func (t *Transport) registryGet(ctx context.Context, ref imageReference, path string, blob bool) ([]byte, error) {
	address := ref.origin + "/v2/" + ref.repository + "/" + path
	body, headers, status, err := t.registryRequest(ctx, address, "", blob)
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized {
		realm, err := challengeURL(headers.Get("WWW-Authenticate"), ref)
		if err != nil {
			return nil, err
		}
		response, _, code, err := t.registryRequest(ctx, realm, "", false)
		if err != nil || code != http.StatusOK {
			return nil, fmt.Errorf("anonymous registry token unavailable (HTTP %d)", code)
		}
		var authorization struct {
			Token       string `json:"token"`
			AccessToken string `json:"access_token"`
		}
		if err := DecodeJSON(response, &authorization); err != nil {
			return nil, fmt.Errorf("invalid registry token response")
		}
		if authorization.Token == "" {
			authorization.Token = authorization.AccessToken
		}
		if authorization.Token == "" || strings.ContainsAny(authorization.Token, "\r\n") || (authorization.AccessToken != "" && authorization.Token != authorization.AccessToken) {
			return nil, fmt.Errorf("invalid registry token")
		}
		body, _, status, err = t.registryRequest(ctx, address, authorization.Token, blob)
		if err != nil {
			return nil, err
		}
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("registry object unavailable (HTTP %d)", status)
	}
	return body, nil
}

func verifyDigest(raw []byte, digest string) error {
	got := sha256.Sum256(raw)
	if !imageDigest.MatchString(digest) || "sha256:"+hex.EncodeToString(got[:]) != digest {
		return fmt.Errorf("registry content digest mismatch")
	}
	return nil
}

// CheckImage verifies the immutable manifest, the selected platform manifest,
// and its small config blob. It neither downloads layers nor runs the image.
func (t *Transport) CheckImage(ctx context.Context, image, platform string) error {
	ref, err := parseImage(image)
	if err != nil {
		return err
	}
	osName, architecture, ok := strings.Cut(platform, "/")
	if !ok || osName == "" || architecture == "" {
		return fmt.Errorf("invalid image platform")
	}
	digest := ref.digest
	for depth := 0; depth < 3; depth++ {
		raw, err := t.registryGet(ctx, ref, "manifests/"+digest, false)
		if err != nil {
			return err
		}
		if err := verifyDigest(raw, digest); err != nil {
			return err
		}
		var manifest struct {
			SchemaVersion int    `json:"schemaVersion"`
			MediaType     string `json:"mediaType"`
			Manifests     []struct {
				Digest   string
				Platform struct {
					OS           string
					Architecture string
				}
			}
			Config struct{ Digest string }
		}
		if err := DecodeJSON(raw, &manifest); err != nil {
			return fmt.Errorf("invalid image manifest")
		}
		if manifest.SchemaVersion != 2 {
			return fmt.Errorf("unsupported image manifest version")
		}
		switch manifest.MediaType {
		case "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json":
			matches := []string{}
			for _, candidate := range manifest.Manifests {
				if candidate.Platform.OS == osName && candidate.Platform.Architecture == architecture {
					matches = append(matches, candidate.Digest)
				}
			}
			if len(matches) != 1 || !imageDigest.MatchString(matches[0]) {
				return fmt.Errorf("image platform missing or ambiguous")
			}
			digest = matches[0]
		case "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json":
			if !imageDigest.MatchString(manifest.Config.Digest) {
				return fmt.Errorf("invalid image config digest")
			}
			config, err := t.registryGet(ctx, ref, "blobs/"+manifest.Config.Digest, true)
			if err != nil {
				return err
			}
			if err := verifyDigest(config, manifest.Config.Digest); err != nil {
				return err
			}
			var target struct {
				OS           string
				Architecture string
			}
			if err := DecodeJSON(config, &target); err != nil {
				return fmt.Errorf("invalid image config")
			}
			if target.OS != osName || target.Architecture != architecture {
				return fmt.Errorf("image config platform differs from bootstrap")
			}
			return nil
		default:
			return fmt.Errorf("unsupported image manifest media type")
		}
	}
	return fmt.Errorf("image index nesting exceeds limit")
}

func (t *Transport) CheckImages(ctx context.Context, doc Document, result *Result) {
	if len(doc.Software) == 0 {
		return
	}
	var software struct {
		Platform   string
		Components map[string]struct{ Image string }
	}
	if err := DecodeJSON(doc.Software, &software); err != nil {
		result.check("software", "", func() error { return err })
		return
	}
	roles := make([]string, 0, len(software.Components))
	for role := range software.Components {
		roles = append(roles, role)
	}
	sort.Strings(roles)
	cache := map[string]error{}
	for _, role := range roles {
		image := software.Components[role].Image
		result.check("image:"+role, image, func() error {
			if err, exists := cache[image]; exists {
				return err
			}
			err := t.CheckImage(ctx, image, software.Platform)
			cache[image] = err
			return err
		})
	}
}
