package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Paths are explicit: epoch indexes, group IDs, and PoC stage heights are not
// interchangeable with the historical application query height.
type ApplicationRequest struct {
	Node      string `json:"node"`
	Height    int64  `json:"height"`
	Path      string `json:"path"`
	Paginated bool   `json:"paginated,omitempty"`
}

type ApplicationEvidence struct {
	RequestedHeight int64  `json:"requested_height"`
	ReportedHeight  string `json:"reported_height,omitempty"`
	Page            int    `json:"page"`
	Complete        bool   `json:"complete"` // Only the terminal page can close a query.
}

var applicationPath = regexp.MustCompile(`^/(productscience/inference/inference/(params|get_current_epoch|current_epoch_group_data|epoch_group_data(/[0-9]+)?|participant(/[a-zA-Z0-9]+)?|epoch_group_validations(/[a-zA-Z0-9]+/[0-9]+)?|(all_poc_v2_store_commits|all_mlnode_weight_distributions|poc_validation_snapshot|confirmation_poc_events|poc_v2_validations_for_stage)/[0-9]+|poc_batches_for_stage/[0-9]+|poc_validations_for_stage/[0-9]+|excluded_participants/[0-9]+|epoch_performance_summary/[0-9]+|participant_allow_list|last_upgrade_height)|cosmos/group/v1/(group_info|group_members)/[0-9]+|cosmos/staking/v1beta1/(params|validators(/[a-zA-Z0-9]+)?)|cosmos/slashing/v1beta1/(params|signing_infos(/[a-zA-Z0-9]+)?))$`)

func validateApplication(c Config, from, to int64) error {
	if len(c.ApplicationRequests) > 128 {
		return fmt.Errorf("application_requests exceeds 128 queries")
	}
	nodes := map[string]Node{}
	for _, n := range c.Nodes {
		nodes[n.ID] = n
	}
	seen := map[string]bool{}
	for _, r := range c.ApplicationRequests {
		n, ok := nodes[r.Node]
		u, err := url.Parse(n.REST)
		if !ok || err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/" && u.Path != "/chain-api") {
			return fmt.Errorf("application query requires an explicit HTTP(S) REST origin for node %s", r.Node)
		}
		if r.Height < from || r.Height > to+1 || !applicationPath.MatchString(r.Path) {
			return fmt.Errorf("invalid application query height or path")
		}
		key := fmt.Sprintf("%s/%d%s", r.Node, r.Height, r.Path)
		if seen[key] {
			return fmt.Errorf("duplicate application query")
		}
		seen[key] = true
	}
	return nil
}

func (x *collector) application(n Node, r ApplicationRequest, index int) {
	client := *x.client
	// Never forward a historical request to a redirect target.
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	next := ""
	seen := map[string]bool{}
	budget := maxSourceBytes
	for page := 1; page <= 32; page++ {
		at := time.Now().UTC()
		u, _ := url.Parse(strings.TrimRight(n.REST, "/") + r.Path)
		q := u.Query()
		if r.Paginated {
			q.Set("pagination.limit", "100")
			if next != "" {
				q.Set("pagination.key", next)
			}
		}
		u.RawQuery = q.Encode()
		req, err := http.NewRequest(http.MethodGet, u.String(), nil)
		if err != nil {
			return
		} // Validated before the collector starts.
		req.Header.Set("x-cosmos-block-height", strconv.FormatInt(r.Height, 10))
		evidence := &ApplicationEvidence{RequestedHeight: r.Height, Page: page}
		var b []byte
		resp, err := client.Do(req)
		if err == nil {
			evidence.ReportedHeight = resp.Header.Get("x-cosmos-block-height")
			b, err = io.ReadAll(io.LimitReader(resp.Body, int64(budget)+1))
			resp.Body.Close()
			if len(b) > budget {
				b = nil
				err = fmt.Errorf("application query exceeds %d byte budget", maxSourceBytes)
			}
			budget -= len(b)
			if resp.StatusCode != 200 {
				err = fmt.Errorf("application HTTP %d: unavailable or rejected historical query", resp.StatusCode)
			}
			if err == nil && evidence.ReportedHeight != strconv.FormatInt(r.Height, 10) {
				err = fmt.Errorf("historical height unverified: requested %d, reported %q", r.Height, evidence.ReportedHeight)
			}
		}
		var body struct {
			Code       json.RawMessage `json:"code"`
			Pagination *struct {
				NextKey json.RawMessage `json:"next_key"`
			} `json:"pagination"`
		}
		if err == nil {
			err = json.Unmarshal(b, &body)
			if err == nil && (strings.TrimSpace(string(b)) == "null" || len(body.Code) > 0) {
				err = fmt.Errorf("application response is not a query result")
			}
			if err == nil {
				next = ""
				if body.Pagination != nil && len(body.Pagination.NextKey) > 0 {
					err = json.Unmarshal(body.Pagination.NextKey, &next)
				}
				if r.Paginated && (body.Pagination == nil || body.Pagination.NextKey == nil) {
					err = fmt.Errorf("pagination completion unverified")
				}
				if next != "" && (!r.Paginated || seen[next] || page == 32 || budget <= 0) {
					err = fmt.Errorf("application pagination incomplete: disabled, repeated cursor, or limit reached")
				}
				seen[next] = true
				evidence.Complete = err == nil && next == ""
			}
		}
		name := fmt.Sprintf("application-%d-%d-%d.json", index, r.Height, page)
		x.save(n, name, u.String(), b, err, nil, at)
		x.mu.Lock()
		for i := range x.d.Receipts {
			if x.d.Receipts[i].Path == filepath.Join(x.dir, n.ID+"-"+name) {
				if x.d.Receipts[i].Error != "" {
					evidence.Complete = false
				}
				x.d.Receipts[i].Application = evidence
			}
		}
		x.mu.Unlock()
		if err != nil || evidence.Complete {
			return
		}
	}
}
