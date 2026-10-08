// Package network owns bounded, injectable HTTP observation clients.
package network

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const DefaultRequestTimeout = 10 * time.Second

type HTTPClient struct {
	Client            *http.Client
	RequestTimeout    time.Duration
	AllowHTTPForTests bool
}

func NewHTTPClient(client *http.Client) HTTPClient {
	if client == nil {
		client = &http.Client{}
	}
	return HTTPClient{Client: client, RequestTimeout: DefaultRequestTimeout}
}

func (c HTTPClient) Do(ctx context.Context, req *http.Request) (*http.Response, error) {
	if ctx == nil || req == nil {
		return nil, errors.New("request and context are required")
	}
	if err := c.validateURL(req.URL); err != nil {
		return nil, err
	}
	timeout := c.RequestTimeout
	if timeout <= 0 {
		timeout = DefaultRequestTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return c.Client.Do(req.WithContext(ctx))
}

func (c HTTPClient) Get(ctx context.Context, rawURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	return c.Do(ctx, req)
}

func (c HTTPClient) validateURL(value *url.URL) error {
	if value == nil || value.Host == "" || value.User != nil || value.RawQuery != "" || value.Fragment != "" {
		return errors.New("invalid observation URL")
	}
	if value.Scheme == "https" {
		return nil
	}
	if value.Scheme == "http" && c.AllowHTTPForTests && isLoopback(value.Hostname()) {
		return nil
	}
	return errors.New("HTTPS is required outside explicit loopback tests")
}

func isLoopback(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1" || strings.HasPrefix(host, "127.")
}
