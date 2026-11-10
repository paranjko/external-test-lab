// Package config provides strict validation for gonkactl's embedded contracts.
package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"

	"github.com/dlclark/regexp2"
	"github.com/paranjko/external-test-lab/gonkactl/internal/assets"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

type validator struct{ schemas map[string]*jsonschema.Schema }
type localOnlyLoader struct{}
type ecmaRegexp regexp2.Regexp

func (r *ecmaRegexp) MatchString(value string) bool {
	matched, err := (*regexp2.Regexp)(r).MatchString(value)
	return err == nil && matched
}
func (r *ecmaRegexp) String() string { return (*regexp2.Regexp)(r).String() }

func compileECMA(pattern string) (jsonschema.Regexp, error) {
	compiled, err := regexp2.Compile(pattern, regexp2.ECMAScript)
	return (*ecmaRegexp)(compiled), err
}

func (localOnlyLoader) Load(url string) (any, error) {
	return nil, fmt.Errorf("remote schema loading is disabled for %q", url)
}

func NewValidator() (contracts.Validator, error) {
	raw, err := assets.Schema("runtime.schema.json")
	if err != nil {
		return nil, err
	}
	document, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("decode embedded runtime schema: %w", err)
	}
	compiler := jsonschema.NewCompiler()
	compiler.AssertFormat()
	compiler.UseLoader(localOnlyLoader{})
	compiler.UseRegexpEngine(compileECMA)
	if err := compiler.AddResource("runtime.schema.json", document); err != nil {
		return nil, err
	}
	if err := compiler.AddResource("https://gonka-dev.net/gonkactl/contracts/v1/runtime.schema.json", document); err != nil {
		return nil, err
	}
	recoveryRaw, err := assets.Schema("recovery.schema.json")
	if err != nil {
		return nil, err
	}
	recoveryDocument, err := jsonschema.UnmarshalJSON(bytes.NewReader(recoveryRaw))
	if err != nil {
		return nil, fmt.Errorf("decode embedded recovery schema: %w", err)
	}
	if err := compiler.AddResource("recovery.schema.json", recoveryDocument); err != nil {
		return nil, err
	}
	if err := compiler.AddResource("https://gonka-dev.net/gonkactl/contracts/v1/recovery.schema.json", recoveryDocument); err != nil {
		return nil, err
	}
	schemas := make(map[string]*jsonschema.Schema)
	for _, ref := range []string{"result", "operation_receipt", "guard", "journal", "transaction_intent"} {
		schema, err := compiler.Compile("runtime.schema.json#/$defs/" + ref)
		if err != nil {
			return nil, fmt.Errorf("compile %s: %w", ref, err)
		}
		schemas["runtime.schema.json#/$defs/"+ref] = schema
	}
	for _, ref := range []string{"manifest", "approval_payload", "approval", "phase_proof"} {
		schema, err := compiler.Compile("recovery.schema.json#/$defs/" + ref)
		if err != nil {
			return nil, fmt.Errorf("compile recovery %s: %w", ref, err)
		}
		schemas["recovery.schema.json#/$defs/"+ref] = schema
	}
	return validator{schemas: schemas}, nil
}

func (v validator) Validate(ref string, value json.RawMessage) error {
	schema, ok := v.schemas[ref]
	if !ok {
		return fmt.Errorf("unknown local schema %q", ref)
	}
	if err := rejectDuplicateKeys(value); err != nil {
		return err
	}
	decoded, err := jsonschema.UnmarshalJSON(bytes.NewReader(value))
	if err != nil {
		return fmt.Errorf("decode JSON: %w", err)
	}
	if err := schema.Validate(decoded); err != nil {
		return err
	}
	return nil
}

func rejectDuplicateKeys(value []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(value))
	decoder.UseNumber()
	if err := walkJSON(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return fmt.Errorf("trailing JSON value")
	}
	return nil
}

func walkJSON(decoder *json.Decoder) error {
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
		keys := map[string]struct{}{}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("object key is not a string")
			}
			if _, seen := keys[key]; seen {
				return fmt.Errorf("duplicate object key %q", key)
			}
			keys[key] = struct{}{}
			if err := walkJSON(decoder); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
		return err
	case '[':
		for decoder.More() {
			if err := walkJSON(decoder); err != nil {
				return err
			}
		}
		_, err = decoder.Token()
		return err
	default:
		return fmt.Errorf("unexpected JSON delimiter")
	}
}
