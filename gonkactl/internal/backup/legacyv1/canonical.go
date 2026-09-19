package legacyv1

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
)

// CanonicalGenesis applies the legacy producer transformation before rendering
// sorted, two-space JSON with one terminal LF. Raw bootstrap bytes are never
// substituted for these canonical bytes.
func CanonicalGenesis(raw []byte) ([]byte, string, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, "", err
	}
	if decoder.Decode(&struct{}{}) == nil {
		return nil, "", errors.New("trailing JSON")
	}
	root, ok := value.(map[string]any)
	if !ok {
		return nil, "", errors.New("genesis must be an object")
	}
	delete(root, "app_name")
	delete(root, "app_version")
	if appHash, exists := root["app_hash"]; exists && (appHash == nil || appHash == false) {
		root["app_hash"] = ""
	}
	if height, exists := root["initial_height"]; exists {
		root["initial_height"] = jqString(height)
	}
	if consensus, exists := root["consensus"]; exists {
		if object, ok := consensus.(map[string]any); ok {
			if params, present := object["params"]; present && jqTruthy(params) {
				root["consensus_params"] = params
			}
		}
		delete(root, "consensus")
	}
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(root); err != nil {
		return nil, "", err
	}
	encoded := output.Bytes()
	sum := sha256.Sum256(encoded)
	return encoded, hex.EncodeToString(sum[:]), nil
}

// RawBootstrapDigest is deliberately separate from CanonicalGenesis so a raw
// genesis-byte binding cannot be mistaken for a legacy identity digest.
func RawBootstrapDigest(raw []byte) string { return Digest(raw) }

func jqTruthy(value any) bool {
	if value == nil {
		return false
	}
	if boolean, ok := value.(bool); ok {
		return boolean
	}
	return true
}

func jqString(value any) string {
	if number, ok := value.(json.Number); ok {
		return number.String()
	}
	if text, ok := value.(string); ok {
		return text
	}
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
