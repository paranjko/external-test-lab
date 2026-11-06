package harness

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// EncodeTrace serializes one run-bound trace as indented JSON. It does not
// validate evidence contents or qualify the runtime; Validate must be called
// with the expected case requirements before the result is consumed.
func EncodeTrace(w io.Writer, trace Trace) error {
	if w == nil {
		return fmt.Errorf("trace writer is required")
	}
	if err := validateDocumentShape(trace); err != nil {
		return err
	}
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(trace)
}

// DecodeTrace strictly decodes one trace document. Unknown fields, duplicate
// object keys, trailing JSON values, invalid run bindings, and empty event
// streams fail closed. Evidence digests still require external verification.
func DecodeTrace(r io.Reader) (Trace, error) {
	var trace Trace
	if r == nil {
		return trace, fmt.Errorf("trace reader is required")
	}
	raw, err := io.ReadAll(r)
	if err != nil {
		return trace, fmt.Errorf("read trace: %w", err)
	}
	if err := rejectDuplicateKeys(raw); err != nil {
		return trace, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&trace); err != nil {
		return trace, fmt.Errorf("decode trace: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return trace, fmt.Errorf("trace document contains trailing JSON")
		}
		return trace, fmt.Errorf("decode trailing trace data: %w", err)
	}
	if err := validateDocumentShape(trace); err != nil {
		return trace, err
	}
	return trace, nil
}

// DecodeAndValidateTrace is the adapter entry point for a producer document.
// A successful Result means internal consistency only.
func DecodeAndValidateTrace(r io.Reader, req Requirements) (Result, error) {
	trace, err := DecodeTrace(r)
	if err != nil {
		return Result{}, err
	}
	return Validate(trace, req)
}

func validateDocumentShape(trace Trace) error {
	if err := contract.ValidateBinding(trace.Binding); err != nil {
		return fmt.Errorf("invalid trace binding: %w", err)
	}
	if len(trace.Observations) == 0 {
		return fmt.Errorf("trace must contain at least one observation")
	}
	return nil
}

// rejectDuplicateKeys enforces JSON's unique-member requirement recursively;
// encoding/json otherwise silently accepts a later duplicate field value.
func rejectDuplicateKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := scanJSONValue(decoder); err != nil {
		return fmt.Errorf("invalid trace JSON: %w", err)
	}
	if _, err := decoder.Token(); err != io.EOF {
		if err == nil {
			return fmt.Errorf("trace document contains trailing JSON")
		}
		return fmt.Errorf("invalid trailing trace JSON: %w", err)
	}
	return nil
}

func scanJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("object member name is not a string")
			}
			if seen[key] {
				return fmt.Errorf("duplicate object key %q", key)
			}
			seen[key] = true
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil {
			return err
		}
		if end != json.Delim('}') {
			return fmt.Errorf("unterminated JSON object")
		}
	case '[':
		for decoder.More() {
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil {
			return err
		}
		if end != json.Delim(']') {
			return fmt.Errorf("unterminated JSON array")
		}
	default:
		return fmt.Errorf("unexpected JSON delimiter %q", delim)
	}
	return nil
}
