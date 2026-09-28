package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
)

const inferencePrefix = "/productscience/inference/inference/"

// Discover identifiers from height-checked replies. Never substitute an epoch
// index for a stage height or quietly query outside the owner's requested range.
// The same discovery runs under collect and report, and its exact requests are
// saved with the raw receipts for offline interpretation.
func (x *collector) discoverApplication() error {
	add := func(n Node, h int64, path string, paginated bool) error {
		if h < x.d.From || h > x.d.To {
			return nil
		}
		for _, r := range x.d.Config.ApplicationRequests {
			if r.Node == n.ID && r.Height == h && r.Path == path {
				return nil
			}
		}
		r := ApplicationRequest{n.ID, h, path, paginated}
		c := x.d.Config
		c.ApplicationRequests = append(append([]ApplicationRequest{}, c.ApplicationRequests...), r)
		if err := validateApplication(c, x.d.From, x.d.To); err != nil {
			return err
		}
		x.d.Config.ApplicationRequests = c.ApplicationRequests
		x.application(n, r, len(c.ApplicationRequests)-1)
		return nil
	}
	for _, n := range x.d.Config.Nodes {
		if n.REST == "" {
			continue
		}
		for _, p := range []string{"params", "current_epoch_group_data"} {
			if err := add(n, x.d.To, inferencePrefix+p, false); err != nil {
				return err
			}
		}
		group := object(x.applicationBody(n.ID, x.d.To, inferencePrefix+"current_epoch_group_data")["epoch_group_data"])
		params := object(object(x.applicationBody(n.ID, x.d.To, inferencePrefix+"params")["params"])["epoch_params"])
		stage := number(str(group["poc_start_block_height"]))
		duration := number(str(params["poc_stage_duration"]))
		delay := number(str(params["poc_validation_delay"]))
		validation := number(str(params["poc_validation_duration"]))
		if stage <= 0 || stage > x.d.To || duration <= 0 || duration > 10000 || delay < 0 || delay > 10000 || validation <= 0 || validation > 10000 || duration+delay+validation > 10000 || stage > (1<<63-1)-10002 {
			continue
		}
		start := stage + duration + delay
		decision := start + validation
		heights := []int64{x.d.From, stage - 1, decision + 1, decision + 2, x.d.To}
		sort.Slice(heights, func(i, j int) bool { return heights[i] < heights[j] })
		for _, h := range heights {
			for _, p := range []string{"current_epoch_group_data", "params", "participant"} {
				if err := add(n, h, inferencePrefix+p, p == "participant"); err != nil {
					return err
				}
			}
			if err := add(n, h, "/cosmos/staking/v1beta1/validators", true); err != nil {
				return err
			}
		}
		for _, p := range []string{"all_poc_v2_store_commits", "poc_v2_validations_for_stage", "all_mlnode_weight_distributions"} {
			if err := add(n, decision+2, fmt.Sprintf("%s%s/%d", inferencePrefix, p, stage), false); err != nil {
				return err
			}
		}
		if err := add(n, start, fmt.Sprintf("%spoc_validation_snapshot/%d", inferencePrefix, stage), false); err != nil {
			return err
		}
		epoch, groupID := number(str(group["epoch_index"])), number(str(group["epoch_group_id"]))
		if epoch > 0 {
			for _, p := range []string{"excluded_participants", "confirmation_poc_events", "epoch_performance_summary"} {
				if err := add(n, decision+2, fmt.Sprintf("%s%s/%d", inferencePrefix, p, epoch), false); err != nil {
					return err
				}
			}
		}
		if groupID > 0 {
			if err := add(n, decision+2, fmt.Sprintf("/cosmos/group/v1/group_members/%d", groupID), true); err != nil {
				return err
			}
		}
	}
	return nil
}

func (x *collector) applicationBody(node string, height int64, path string) map[string]any {
	for _, r := range x.d.Receipts {
		if r.Node != node || r.Error != "" || r.Application == nil || !r.Application.Complete || r.Application.Page != 1 || r.Application.ReportedHeight != fmt.Sprint(height) {
			continue
		}
		u, err := url.Parse(r.Source)
		if err != nil || strings.TrimPrefix(u.Path, "/chain-api") != path {
			continue
		}
		b, err := os.ReadFile(r.Path)
		if err != nil {
			continue
		}
		var body map[string]any
		if json.Unmarshal(b, &body) == nil {
			return body
		}
	}
	return nil
}
