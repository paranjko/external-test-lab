//go:build linux

package incidenthost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type dockerAPI interface {
	inspect(context.Context, string) (dockerContainer, error)
	listVolumeConsumers(context.Context, string) ([]dockerSummary, error)
	inspectImage(context.Context, string) (dockerImage, error)
	stop(context.Context, string, int) error
	create(context.Context, string, dockerCreate) (string, error)
	start(context.Context, string) error
	kill(context.Context, string, string) error
	logs(context.Context, string, int) (string, error)
}

type dockerContainer struct {
	ID     string `json:"Id"`
	Image  string `json:"Image"`
	Name   string `json:"Name"`
	Config struct {
		Image      string            `json:"Image"`
		Entrypoint []string          `json:"Entrypoint"`
		Cmd        []string          `json:"Cmd"`
		Env        []string          `json:"Env"`
		Hostname   string            `json:"Hostname"`
		Labels     map[string]string `json:"Labels"`
	} `json:"Config"`
	HostConfig struct {
		NetworkMode   string `json:"NetworkMode"`
		RestartPolicy struct {
			Name string `json:"Name"`
		} `json:"RestartPolicy"`
		Privileged bool `json:"Privileged"`
	} `json:"HostConfig"`
	State struct {
		Status   string `json:"Status"`
		Running  bool   `json:"Running"`
		Pid      int    `json:"Pid"`
		ExitCode int    `json:"ExitCode"`
	} `json:"State"`
	Mounts []struct {
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Type        string `json:"Type"`
		RW          bool   `json:"RW"`
	} `json:"Mounts"`
	NetworkSettings struct {
		Networks map[string]struct {
			Aliases []string `json:"Aliases"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

type dockerSummary struct {
	ID     string `json:"Id"`
	State  string `json:"State"`
	Mounts []struct {
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Type        string `json:"Type"`
	} `json:"Mounts"`
}

type dockerImage struct {
	ID string `json:"Id"`
}

type dockerCreate struct {
	createConfig
	HostConfig       createHostConfig       `json:"HostConfig"`
	NetworkingConfig createNetworkingConfig `json:"NetworkingConfig"`
}

type createConfig struct {
	Image      string            `json:"Image"`
	Entrypoint []string          `json:"Entrypoint"`
	Cmd        []string          `json:"Cmd"`
	Env        []string          `json:"Env"`
	Labels     map[string]string `json:"Labels"`
}

type createHostConfig struct {
	NetworkMode   string `json:"NetworkMode"`
	RestartPolicy struct {
		Name string `json:"Name"`
	} `json:"RestartPolicy"`
	Mounts []dockerMount `json:"Mounts"`
}

type dockerMount struct {
	Type     string `json:"Type"`
	Source   string `json:"Source"`
	Target   string `json:"Target"`
	ReadOnly bool   `json:"ReadOnly,omitempty"`
}

type createNetworkingConfig struct {
	EndpointsConfig map[string]struct {
		Aliases []string `json:"Aliases"`
	} `json:"EndpointsConfig"`
}

type unixDocker struct {
	client     *http.Client
	versionMu  sync.Mutex
	apiVersion string
}

const dockerClientMaxAPIVersion = "1.41"

type dockerHTTPError struct {
	status  int
	method  string
	path    string
	message string
}

func (e *dockerHTTPError) Error() string {
	return fmt.Sprintf("Docker API %s %s: HTTP %d: %s", e.method, e.path, e.status, e.message)
}

func newUnixDocker(socket string) *unixDocker {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	return &unixDocker{client: &http.Client{Transport: transport, Timeout: 30 * time.Second}}
}

func (d *unixDocker) request(ctx context.Context, method, path string, input, output any) error {
	if path != "/version" {
		if err := d.negotiate(ctx); err != nil {
			return err
		}
		path = "/v" + d.apiVersion + path
	}
	var body io.Reader
	if input != nil {
		encoded, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = strings.NewReader(string(encoded))
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, body)
	if err != nil {
		return err
	}
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		var apiErr struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(message, &apiErr)
		if apiErr.Message == "" {
			apiErr.Message = strings.TrimSpace(string(message))
		}
		return &dockerHTTPError{status: resp.StatusCode, method: method, path: path, message: apiErr.Message}
	}
	if output == nil {
		_, err = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		return err
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(output); err != nil {
		return fmt.Errorf("decode Docker API %s %s: %w", method, path, err)
	}
	return nil
}

func (d *unixDocker) negotiate(ctx context.Context) error {
	d.versionMu.Lock()
	defer d.versionMu.Unlock()
	if d.apiVersion != "" {
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker/version", nil)
	if err != nil {
		return err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return fmt.Errorf("negotiate Docker API version: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("negotiate Docker API version: HTTP %d", resp.StatusCode)
	}
	var version struct {
		APIVersion    string `json:"ApiVersion"`
		MinAPIVersion string `json:"MinAPIVersion"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&version); err != nil {
		return fmt.Errorf("decode Docker API version: %w", err)
	}
	server, err := parseAPIVersion(version.APIVersion)
	if err != nil {
		return err
	}
	minimum := apiVersionNumber{major: 1, minor: 24}
	if version.MinAPIVersion != "" {
		minimum, err = parseAPIVersion(version.MinAPIVersion)
		if err != nil {
			return err
		}
	}
	maximum, _ := parseAPIVersion(dockerClientMaxAPIVersion)
	chosen := server
	if chosen.less(maximum) {
		maximum = chosen
	} else {
		chosen = maximum
	}
	if chosen.less(minimum) {
		return fmt.Errorf("Docker API minimum %s exceeds client support %s", minimum, dockerClientMaxAPIVersion)
	}
	d.apiVersion = chosen.String()
	return nil
}

type apiVersionNumber struct {
	major int
	minor int
}

func parseAPIVersion(value string) (apiVersionNumber, error) {
	parts := strings.Split(value, ".")
	if len(parts) != 2 || !allDigits(parts[0]) || !allDigits(parts[1]) {
		return apiVersionNumber{}, fmt.Errorf("invalid Docker API version %q", value)
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(parts[1])
	if majorErr != nil || minorErr != nil || major < 1 {
		return apiVersionNumber{}, fmt.Errorf("invalid Docker API version %q", value)
	}
	version := apiVersionNumber{major: major, minor: minor}
	return version, nil
}

func (v apiVersionNumber) less(other apiVersionNumber) bool {
	return v.major < other.major || (v.major == other.major && v.minor < other.minor)
}

func (v apiVersionNumber) String() string { return fmt.Sprintf("%d.%d", v.major, v.minor) }

func (d *unixDocker) inspect(ctx context.Context, id string) (dockerContainer, error) {
	var out dockerContainer
	err := d.request(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/json", nil, &out)
	return out, err
}

func (d *unixDocker) listVolumeConsumers(ctx context.Context, volume string) ([]dockerSummary, error) {
	filterBytes, _ := json.Marshal(map[string][]string{"volume": {volume}})
	path := "/containers/json?all=0&filters=" + url.QueryEscape(string(filterBytes))
	var out []dockerSummary
	err := d.request(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (d *unixDocker) inspectImage(ctx context.Context, ref string) (dockerImage, error) {
	var out dockerImage
	err := d.request(ctx, http.MethodGet, "/images/"+url.PathEscape(ref)+"/json", nil, &out)
	return out, err
}

func (d *unixDocker) stop(ctx context.Context, id string, timeout int) error {
	path := "/containers/" + url.PathEscape(id) + "/stop?t=" + fmt.Sprint(timeout)
	return d.request(ctx, http.MethodPost, path, nil, nil)
}

func (d *unixDocker) create(ctx context.Context, name string, spec dockerCreate) (string, error) {
	var out struct {
		ID string `json:"Id"`
	}
	path := "/containers/create?name=" + url.QueryEscape(name)
	if err := d.request(ctx, http.MethodPost, path, spec, &out); err != nil {
		return "", err
	}
	if out.ID == "" {
		return "", errors.New("Docker API created a container without an ID")
	}
	return out.ID, nil
}

func (d *unixDocker) start(ctx context.Context, id string) error {
	return d.request(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/start", nil, nil)
}

func (d *unixDocker) kill(ctx context.Context, id, signal string) error {
	return d.request(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/kill?signal="+url.QueryEscape(signal), nil, nil)
}

func (d *unixDocker) logs(ctx context.Context, id string, tail int) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://docker/containers/"+url.PathEscape(id)+"/logs?stdout=1&stderr=1&tail="+fmt.Sprint(tail), nil)
	if err != nil {
		return "", err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		return "", fmt.Errorf("Docker logs HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 128<<10))
	if err != nil {
		return "", err
	}
	return decodeDockerLogStream(data), nil
}

func decodeDockerLogStream(data []byte) string {
	// Docker multiplexes non-TTY stdout/stderr as 8-byte framed records.
	var out strings.Builder
	for len(data) >= 8 && (data[0] == 1 || data[0] == 2) {
		n := int(data[4])<<24 | int(data[5])<<16 | int(data[6])<<8 | int(data[7])
		if n < 0 || n > len(data)-8 {
			return string(data)
		}
		out.Write(data[8 : 8+n])
		data = data[8+n:]
	}
	if len(data) != 0 {
		out.Write(data)
	}
	text := out.String()
	if len(text) > 128<<10 {
		text = text[len(text)-(128<<10):]
	}
	return text
}
