package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

func collectionArguments(args []string, path string) (c Config, from, to int64, err error) {
	if len(args) < 1 || len(args) > 2 {
		err = fmt.Errorf("requires <block_id_from> [block_id_to]")
		return
	}
	from, err = strconv.ParseInt(args[0], 10, 64)
	if err != nil || from < 1 || from == math.MaxInt64 {
		err = fmt.Errorf("invalid start height")
		return
	}
	if len(args) == 2 {
		to, err = strconv.ParseInt(args[1], 10, 64)
		if err != nil || to < from || to == math.MaxInt64 {
			err = fmt.Errorf("invalid end height")
			return
		}
	}
	b, e := os.ReadFile(path)
	if e != nil {
		err = e
		return
	}
	if err = json.Unmarshal(b, &c); err != nil {
		return
	}
	if c.TimeoutSeconds <= 0 {
		c.TimeoutSeconds = 15
	}
	if c.Concurrency < 1 {
		c.Concurrency = 4
	}
	if c.Concurrency > 16 {
		c.Concurrency = 16
	}
	if len(c.Nodes) == 0 || c.PaddingSeconds < 0 {
		err = fmt.Errorf("nodes required and padding must be nonnegative")
		return
	}
	if len(args) == 1 {
		to, err = latestHeight(c.Nodes[0], c.TimeoutSeconds)
		if err != nil {
			return
		}
		fmt.Fprintf(os.Stderr, "Resolved end height from %s status: %d (saved in dataset)\n", c.Nodes[0].ID, to)
	}
	if to < from || to == math.MaxInt64 {
		err = fmt.Errorf("invalid range")
		return
	}
	if to-from > 10000 && len(c.History) == 0 {
		err = fmt.Errorf("large ranges require an explicit bounded history_requests selection")
		return
	}
	if err = validateHistory(c, from, to); err != nil {
		return
	}
	err = validateApplication(c, from, to)
	return
}

func latestHeight(n Node, timeout int) (int64, error) {
	u, err := url.Parse(strings.TrimRight(n.RPC, "/") + "/status")
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return 0, fmt.Errorf("invalid RPC URL")
	}
	client := http.Client{Timeout: time.Duration(timeout) * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Get(u.String())
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return 0, fmt.Errorf("status HTTP %d", res.StatusCode)
	}
	var body struct {
		Result struct {
			Sync struct {
				Height string `json:"latest_block_height"`
			} `json:"sync_info"`
		} `json:"result"`
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, maxSourceBytes)).Decode(&body); err != nil {
		return 0, err
	}
	h, err := strconv.ParseInt(body.Result.Sync.Height, 10, 64)
	if err != nil || h < 1 || h == math.MaxInt64 {
		return 0, fmt.Errorf("status has no valid latest block height")
	}
	return h, nil
}
