package bootstrap

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"path/filepath"
	"reflect"
	"strings"
	"time"
)

type UpdateOptions struct {
	ChainID, Directory, Profile, BaseURL string
	ProgressInterval                     time.Duration
}

// Runtime observations attest node/API release identity, not the runtime
// digests of every auxiliary service. Those come from the approved recipe.
func (t *Transport) CheckRuntimeSoftware(ctx context.Context, doc Document, result *Result) {
	if len(doc.Software) == 0 {
		return
	}
	var software Software
	if err := DecodeJSON(doc.Software, &software); err != nil {
		result.check("software-runtime", "", func() error { return err })
		return
	}
	verified := map[string]bool{}
	for _, seed := range doc.Seeds {
		if seed.API == "" {
			continue
		}
		address := strings.TrimRight(seed.API, "/") + "/v1/versions"
		result.check("software-runtime", address, func() error {
			var observed struct {
				Node Component `json:"node_version"`
				API  Component `json:"api_version"`
			}
			if err := t.query(ctx, address, &observed); err != nil {
				return err
			}
			for role, actual := range map[string]Component{"node": observed.Node, "api": observed.API} {
				wanted := software.Components[role]
				if !commitID.MatchString(wanted.Commit) || actual.Commit != wanted.Commit || strings.TrimPrefix(actual.Version, "v") != strings.TrimPrefix(wanted.Version, "v") {
					return fmt.Errorf("observed %s version/commit differs from software", role)
				}
			}
			var abci struct {
				Result struct{ Response struct{ Version string } }
			}
			if err := t.query(ctx, strings.TrimRight(seed.RPC, "/")+"/abci_info", &abci); err != nil {
				return err
			}
			if strings.TrimPrefix(abci.Result.Response.Version, "v") != strings.TrimPrefix(software.Components["node"].Version, "v") {
				return fmt.Errorf("RPC application version differs from software")
			}
			origin, _ := url.Parse(seed.RPC)
			verified[origin.Hostname()] = true
			return nil
		})
	}
	result.check("software-quorum", "", func() error {
		if len(verified) < 2 {
			return fmt.Errorf("software requires matching runtime observations from two independent seeds")
		}
		return nil
	})
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
	if options.ProgressInterval < 0 || options.ProgressInterval > time.Minute {
		return report, fmt.Errorf("invalid observation interval")
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
	result := Result{ChainID: options.ChainID, BootstrapURL: filepath.Join(options.Directory, options.ChainID+".json"), Checks: []Check{}}
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
		if base.ChainID == "gonka-devnet-community" && !declared {
			return fmt.Errorf("DevNet update requires a complete software recipe")
		}
		seeds, err := t.DiscoverSeeds(ctx, base)
		if err == nil {
			base.Seeds = seeds
		}
		return err
	})
	if !result.Checks[len(result.Checks)-1].OK {
		return finish()
	}
	t.CheckSeeds(ctx, base, options.ProgressInterval, &result)
	t.CheckRuntimeSoftware(ctx, base, &result)
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
