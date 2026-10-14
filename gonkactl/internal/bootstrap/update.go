package bootstrap

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"time"
)

type UpdateOptions struct {
	Policy                               string
	ChainID, Directory, Profile, BaseURL string
}

func equivalentJSON(a, b []byte) bool {
	var left, right any
	return DecodeJSON(a, &left) == nil && DecodeJSON(b, &right) == nil && reflect.DeepEqual(left, right)
}

func (t *Transport) Update(ctx context.Context, options UpdateOptions) (Report, error) {
	report := Report{SchemaVersion: 1, ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Results: []Result{}}
	if !chainName.MatchString(options.ChainID) || options.Directory == "" {
		return report, fmt.Errorf("invalid bootstrap output target")
	}
	policy, err := ResolvePolicy(options.Policy, options.ChainID)
	if err != nil {
		return report, err
	}
	if options.BaseURL == "" {
		options.BaseURL = "https://gonka-dev.net"
	}
	if _, err := endpoint(options.BaseURL, "https", "http"); err != nil {
		return report, fmt.Errorf("invalid publication origin")
	}
	var profile []byte
	if options.Profile != "" {
		var err error
		profile, err = readBounded(options.Profile)
		if err != nil {
			return report, err
		}
		if _, err = ParseProfile(profile); err != nil {
			return report, err
		}
	}
	store, err := openPairStore(options.Directory, options.ChainID)
	if err != nil {
		return report, err
	}
	defer store.Close()
	address := strings.TrimRight(options.BaseURL, "/") + "/" + options.ChainID + "/bootstrap.json"
	result := Result{Policy: policy, ChainID: options.ChainID, BootstrapURL: filepath.Join(options.Directory, options.ChainID+".json"), Checks: []Check{}}
	finish := func() (Report, error) {
		result.complete()
		report.Results = append(report.Results, result)
		return report, nil
	}
	var base Document
	result.check("bootstrap-source", address, func() error {
		raw := store.before[0].Data
		if !store.before[0].Exists {
			var err error
			raw, err = t.Get(ctx, address, DocumentLimit)
			if err != nil {
				return err
			}
		}
		var err error
		base, err = Parse(raw, nil)
		if err != nil {
			return err
		}
		if base.ChainID != options.ChainID {
			return fmt.Errorf("bootstrap chain ID differs from requested network")
		}
		return nil
	})
	if !result.Checks[len(result.Checks)-1].OK {
		return finish()
	}
	if profile != nil {
		result.check("software-profile", options.Profile, func() error {
			if len(base.Software) == 0 {
				raw, err := t.Get(ctx, address, DocumentLimit)
				if err != nil {
					return err
				}
				published, err := Parse(raw, nil)
				if err != nil {
					return err
				}
				if published.ChainID != base.ChainID || published.Genesis != base.Genesis {
					return fmt.Errorf("published software source differs from local network lineage")
				}
				base.Software = published.Software
			}
			var err error
			base, err = t.ApplyProfile(ctx, base, profile)
			return err
		})
		if !result.Checks[len(result.Checks)-1].OK {
			return finish()
		}
	}
	declared := len(base.Software) > 0
	result.SoftwareDeclared = &declared
	result.check("seed-selection", address, func() error {
		if policy == "testnet" {
			refreshed, err := t.refreshTestnet(ctx, base)
			if err == nil {
				base = refreshed
			}
			return err
		}
		seeds, err := t.discoverSeeds(ctx, base, policy == "devnet", &result)
		if err == nil {
			base.Seeds = seeds
		}
		return err
	})
	if !result.Checks[len(result.Checks)-1].OK {
		return finish()
	}
	t.CheckSeeds(ctx, base, &result)
	t.CheckImages(ctx, base, &result)
	result.complete()
	if !result.OK {
		return finish()
	}
	result.check("write-pair", result.BootstrapURL, func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		raw, err := json.MarshalIndent(base, "", "  ")
		if err != nil {
			return err
		}
		raw = append(raw, '\n')
		if equivalentJSON(raw, store.before[0].Data) {
			raw = store.before[0].Data
		}
		report.Changed, err = store.Commit(raw, base.ENV())
		return err
	})
	return finish()
}
