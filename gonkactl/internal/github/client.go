package github

import (
	"context"
	"fmt"
	"net/http"
)

type Client struct {
	HTTP  *http.Client
	Token string
}

func (c Client) Read(ctx context.Context, url string) (*http.Response, error) {
	if c.HTTP == nil {
		return nil, fmt.Errorf("HTTP client required")
	}
	r, e := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if e != nil {
		return nil, e
	}
	return c.HTTP.Do(r)
}
func (c Client) Request(ctx context.Context, method, url string, body any) (*http.Request, error) {
	if method != http.MethodPost {
		return nil, fmt.Errorf("only explicit POST mutations supported")
	}
	r, e := http.NewRequestWithContext(ctx, method, url, nil)
	if e == nil && c.Token != "" {
		r.Header.Set("Authorization", "Bearer "+c.Token)
	}
	return r, e
}
