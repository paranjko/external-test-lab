package bootstrap

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var chainName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

type ValidateOptions struct {
	Policy            string
	ChainID           string
	Directory         string
	ExpectedDirectory string
	BaseURL           string
	ProgressInterval  time.Duration
}

type Report struct {
	Changed       bool     `json:"changed"`
	SchemaVersion int      `json:"schema_version"`
	ObservedAt    string   `json:"observed_at"`
	Results       []Result `json:"results"`
}

func readBounded(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read local bootstrap file %s", filepath.Base(path))
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("bootstrap input is not a regular file")
	}
	body, err := io.ReadAll(io.LimitReader(file, DocumentLimit+1))
	if err != nil {
		return nil, fmt.Errorf("cannot read bootstrap input")
	}
	if len(body) > DocumentLimit {
		return nil, fmt.Errorf("bootstrap input exceeds size limit")
	}
	return body, nil
}

func readPair(directory, chain string) ([]byte, []byte, error) {
	// Writers retain their lock file. Readers never create one: if the first
	// writer creates it during an unlocked read, retry under its shared lock.
	lockPath := filepath.Join(directory, ".gonkactl-"+chain+".lock")
	lock, err := os.Open(lockPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	if lock != nil {
		defer lock.Close()
		info, err := lock.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() != 0 {
			return nil, nil, fmt.Errorf("unsafe bootstrap lock file")
		}
		if err := lockShared(lock); err != nil {
			return nil, nil, fmt.Errorf("bootstrap update is in progress")
		}
	}
	if err := pendingTransaction(directory, chain); err != nil {
		return nil, nil, err
	}
	raw, err := readBounded(filepath.Join(directory, chain+".json"))
	if err != nil {
		return nil, nil, err
	}
	env, err := readBounded(filepath.Join(directory, chain+".env"))
	if err == nil {
		err = pendingTransaction(directory, chain)
	}
	if lock == nil {
		if _, statErr := os.Lstat(lockPath); statErr == nil {
			return readPair(directory, chain)
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return nil, nil, statErr
		}
	}
	return raw, env, err
}

// Validate validates exactly one network. Inventory traversal, report retention,
// GitHub output files and notifications remain outside the installed CLI.
func (t *Transport) Validate(ctx context.Context, options ValidateOptions) (Report, error) {
	report := Report{SchemaVersion: 1, ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Results: []Result{}}
	if !chainName.MatchString(options.ChainID) {
		return report, fmt.Errorf("invalid chain ID")
	}
	policy, policyErr := ResolvePolicy(options.Policy, options.ChainID)
	if policyErr != nil {
		return report, policyErr
	}
	if options.Directory != "" && options.ExpectedDirectory != "" {
		return report, fmt.Errorf("--path and --compare-published are mutually exclusive")
	}
	if options.ProgressInterval < 0 || options.ProgressInterval > time.Minute {
		return report, fmt.Errorf("invalid observation interval")
	}
	if options.BaseURL == "" {
		options.BaseURL = "https://gonka-dev.net"
	}
	if _, err := endpoint(options.BaseURL, "https", "http"); err != nil {
		return report, fmt.Errorf("invalid publication origin")
	}
	address := strings.TrimRight(options.BaseURL, "/") + "/" + options.ChainID + "/bootstrap.json"
	result := Result{Policy: policy, ChainID: options.ChainID, BootstrapURL: address, Checks: []Check{}}
	var raw, env, schema, expectedJSON, expectedENV []byte
	var err error
	if options.ExpectedDirectory != "" {
		expectedJSON, expectedENV, err = readPair(options.ExpectedDirectory, options.ChainID)
		if err != nil {
			return report, err
		}
	}
	if options.Directory != "" {
		raw, env, err = readPair(options.Directory, options.ChainID)
		if err != nil {
			return report, err
		}
		result.BootstrapURL = filepath.Join(options.Directory, options.ChainID+".json")
	} else {
		result.check("schema", SchemaURL, func() error { schema, err = t.Get(ctx, SchemaURL, DocumentLimit); return err })
		if err != nil {
			report.Results = append(report.Results, result)
			return report, nil
		}
		result.check("fetch", address, func() error { raw, err = t.Get(ctx, address, DocumentLimit); return err })
		result.check("publication-env", strings.TrimSuffix(address, ".json")+".env", func() error {
			var fetchErr error
			env, fetchErr = t.Get(ctx, strings.TrimSuffix(address, ".json")+".env", DocumentLimit)
			if fetchErr != nil {
				return fetchErr
			}
			if expectedENV != nil && !bytes.Equal(env, expectedENV) {
				return fmt.Errorf("published ENV bytes differ from repository")
			}
			return nil
		})
		if expectedJSON != nil {
			result.check("publication-json", address, func() error {
				if !bytes.Equal(raw, expectedJSON) {
					return fmt.Errorf("published JSON bytes differ from repository")
				}
				return nil
			})
		}
	}
	var doc Document
	result.check("bootstrap", result.BootstrapURL, func() error {
		var parseErr error
		doc, parseErr = Parse(raw, schema)
		if parseErr != nil {
			return parseErr
		}
		if doc.ChainID != options.ChainID {
			return fmt.Errorf("bootstrap chain ID differs from requested network")
		}
		return nil
	})
	if !result.Checks[len(result.Checks)-1].OK {
		report.Results = append(report.Results, result)
		return report, nil
	}
	softwareDeclared := len(doc.Software) > 0
	result.SoftwareDeclared = &softwareDeclared
	result.check("env-projection", result.BootstrapURL, func() error {
		if !bytes.Equal(env, doc.ENV()) {
			return fmt.Errorf("ENV differs from deterministic JSON projection")
		}
		return nil
	})
	t.checkSeeds(ctx, doc, options.ProgressInterval, policy == "testnet", &result)
	t.CheckImages(ctx, doc, &result)
	result.complete()
	report.Results = append(report.Results, result)
	return report, nil
}
