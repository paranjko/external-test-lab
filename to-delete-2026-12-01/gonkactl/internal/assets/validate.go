package assets

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sort"
)

type manifest struct {
	Version string                    `json:"version"`
	Bundles map[string]bundleManifest `json:"bundles"`
}

type bundleManifest struct {
	SHA256  string            `json:"sha256"`
	Members map[string]string `json:"members"`
}

func validateBundles(manifestBytes, runtime, profiles []byte) error {
	var value manifest
	decoder := json.NewDecoder(bytes.NewReader(manifestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return fmt.Errorf("decode embedded manifest: %w", err)
	}
	if value.Version != "v1" || len(value.Bundles) != 2 {
		return fmt.Errorf("invalid embedded manifest shape")
	}
	for name, contents := range map[string][]byte{"runtime.tar": runtime, "profiles.tar": profiles} {
		bundle, ok := value.Bundles[name]
		if !ok || bundle.SHA256 != digest(contents) || len(bundle.Members) == 0 {
			return fmt.Errorf("invalid embedded bundle %q", name)
		}
		if err := validateMembers(contents, bundle.Members); err != nil {
			return fmt.Errorf("validate embedded bundle %q: %w", name, err)
		}
	}
	return nil
}

func validateMembers(contents []byte, expected map[string]string) error {
	reader := tar.NewReader(bytes.NewReader(contents))
	actual := make(map[string]string, len(expected))
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if header.Typeflag != tar.TypeReg || header.Name == "" || actual[header.Name] != "" {
			return fmt.Errorf("invalid tar member %q", header.Name)
		}
		hash := sha256.New()
		if _, err := io.Copy(hash, reader); err != nil {
			return err
		}
		actual[header.Name] = hex.EncodeToString(hash.Sum(nil))
	}
	if len(actual) != len(expected) {
		return fmt.Errorf("member count %d, want %d", len(actual), len(expected))
	}
	keys := make([]string, 0, len(expected))
	for path := range expected {
		keys = append(keys, path)
	}
	sort.Strings(keys)
	for _, path := range keys {
		if actual[path] != expected[path] {
			return fmt.Errorf("digest mismatch for %q", path)
		}
	}
	return nil
}

func digest(contents []byte) string {
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}
