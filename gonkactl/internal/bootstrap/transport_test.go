package bootstrap

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestHTTPBoundsRetriesAndRedirects(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		switch r.URL.Path {
		case "/retry":
			w.WriteHeader(http.StatusServiceUnavailable)
		case "/redirect":
			http.Redirect(w, r, "/ok", http.StatusFound)
		case "/missing":
			w.WriteHeader(http.StatusNotFound)
		default:
			fmt.Fprint(w, "payload")
		}
	}))
	defer server.Close()
	transport := NewTransport()
	transport.RetryDelay = 0
	for _, tc := range []struct {
		path    string
		limit   int64
		count   int32
		success bool
	}{
		{"/ok", 8, 1, true}, {"/ok", 3, 1, false}, {"/retry", 8, 2, false}, {"/redirect", 8, 1, false}, {"/missing", 8, 1, false},
	} {
		t.Run(tc.path, func(t *testing.T) {
			calls.Store(0)
			_, err := transport.Get(context.Background(), server.URL+tc.path, tc.limit)
			if (err == nil) != tc.success || calls.Load() != tc.count {
				t.Fatalf("error=%v calls=%d", err, calls.Load())
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := transport.Get(ctx, server.URL+"/ok", 8); err == nil {
		t.Fatal("cancelled request passed")
	}
	ctx, cancel = context.WithTimeout(context.Background(), time.Millisecond)
	defer cancel()
	if err := wait(ctx, time.Hour); err == nil {
		t.Fatal("cancelled retry wait passed")
	}
}
