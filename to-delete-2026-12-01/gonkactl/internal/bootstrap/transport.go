package bootstrap

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

// Transport bounds unauthenticated public metadata requests. It deliberately
// does not inherit Docker credentials, execute tools, or follow redirects.
type Transport struct {
	Client     *http.Client
	Timeout    time.Duration
	Attempts   int
	RetryDelay time.Duration
}

func NewTransport() *Transport {
	return &Transport{Client: &http.Client{}, Timeout: 10 * time.Second, Attempts: 2, RetryDelay: time.Second}
}

func wait(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (t *Transport) Get(ctx context.Context, address string, limit int64) ([]byte, error) {
	parsed, err := url.Parse(address)
	if err != nil {
		return nil, fmt.Errorf("invalid HTTP URL")
	}
	// REST pagination and immutable source queries are constructed by callers;
	// credentials, fragments and unsafe endpoint components remain forbidden.
	parsed.RawQuery, parsed.ForceQuery = "", false
	if _, err := endpoint(parsed.String(), "https", "http"); err != nil {
		return nil, err
	}
	if t.Client == nil || t.Attempts < 1 || t.Attempts > 3 || t.Timeout <= 0 || limit <= 0 {
		return nil, fmt.Errorf("invalid transport bounds")
	}
	client := *t.Client
	client.Timeout = t.Timeout
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	for attempt := 0; attempt < t.Attempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
		if err != nil {
			return nil, fmt.Errorf("invalid request")
		}
		req.Header.Set("User-Agent", "gonkactl-bootstrap/1")
		response, err := client.Do(req)
		if err == nil {
			if response.StatusCode == http.StatusOK {
				body, readErr := io.ReadAll(io.LimitReader(response.Body, limit+1))
				response.Body.Close()
				if int64(len(body)) > limit {
					return nil, fmt.Errorf("response exceeds size limit")
				}
				if readErr == nil {
					return body, nil
				}
			} else {
				response.Body.Close()
				status := response.StatusCode
				retry := status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504
				if !retry || attempt+1 == t.Attempts {
					return nil, fmt.Errorf("HTTP %d", status)
				}
			}
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if attempt+1 < t.Attempts {
			if err := wait(ctx, t.RetryDelay); err != nil {
				return nil, err
			}
		}
	}
	return nil, fmt.Errorf("connection failed or timed out")
}

func (t *Transport) TCP(ctx context.Context, address string) error {
	u, err := endpoint(address, "tcp")
	if err != nil {
		return err
	}
	if u.Port() == "" || u.Path != "" {
		return fmt.Errorf("invalid P2P endpoint")
	}
	if t.Attempts < 1 || t.Attempts > 3 || t.Timeout <= 0 {
		return fmt.Errorf("invalid transport bounds")
	}
	dialer := net.Dialer{Timeout: t.Timeout}
	for attempt := 0; attempt < t.Attempts; attempt++ {
		connection, err := dialer.DialContext(ctx, "tcp", u.Host)
		if err == nil {
			connection.Close()
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if attempt+1 < t.Attempts {
			if err := wait(ctx, t.RetryDelay); err != nil {
				return err
			}
		}
	}
	return fmt.Errorf("P2P connection failed or timed out")
}
