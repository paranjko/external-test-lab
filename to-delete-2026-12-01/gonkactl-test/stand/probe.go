package stand

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type Observation struct {
	Protocol       string `json:"protocol"`
	URL            string `json:"url"`
	ExpectedStatus int    `json:"expected_status"`
	ActualStatus   int    `json:"actual_status,omitempty"`
	Outcome        string `json:"outcome"`
	Reason         string `json:"reason,omitempty"`
}

// ProbeHealth checks only the declared versioned health route. It intentionally
// makes no chat or inference claim from a 200 response.
func ProbeHealth(ctx context.Context, client *http.Client, baseURL string, adapter Adapter) Observation {
	url := strings.TrimRight(baseURL, "/") + adapter.Health.Path
	result := Observation{Protocol: adapter.Protocol, URL: url, ExpectedStatus: adapter.Health.ExpectedStatus, Outcome: "blocked"}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		result.Reason = err.Error()
		return result
	}
	response, err := client.Do(request)
	if err != nil {
		result.Reason = err.Error()
		return result
	}
	defer response.Body.Close()
	result.ActualStatus = response.StatusCode
	if response.StatusCode == adapter.Health.ExpectedStatus {
		result.Outcome = "passed"
		return result
	}
	result.Reason = fmt.Sprintf("expected HTTP %d, got %d", adapter.Health.ExpectedStatus, response.StatusCode)
	return result
}

func NewProbeClient() *http.Client { return &http.Client{Timeout: 5 * time.Second} }
