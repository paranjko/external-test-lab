package main

import (
	"bytes"
	"encoding/json"
	"regexp"
)

var secretJSONKey = regexp.MustCompile(`(?i)^(api[_-]?key|private[_-]?key|priv_key|password|mnemonic|seed_phrase|authorization|access_token|refresh_token|token|secret)$`)

// Redact values structurally so regex substitutions cannot corrupt JSON objects
// or match harmless key suffixes such as kb_per_input_token.
func redactSource(b []byte) []byte {
	var v any
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.UseNumber()
	if !json.Valid(b) || decoder.Decode(&v) != nil {
		return []byte(redact(string(b)))
	}
	var walk func(any) any
	walk = func(v any) any {
		switch x := v.(type) {
		case map[string]any:
			for k, value := range x {
				if secretJSONKey.MatchString(k) {
					x[k] = "[REDACTED]"
				} else {
					x[k] = walk(value)
				}
			}
			return x
		case []any:
			for i := range x {
				x[i] = walk(x[i])
			}
			return x
		case string:
			return redact(x)
		default:
			return v
		}
	}
	out, err := json.Marshal(walk(v))
	if err != nil {
		return []byte(`{"redaction_error":true}`)
	}
	return out
}
