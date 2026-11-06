package input

import (
	"encoding/json"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// DecodeSignedDocument enforces the envelope's exact JSON field spellings.
func DecodeSignedDocument(raw []byte) (contract.SignedDocument, error) {
	var document contract.SignedDocument
	var fields map[string]json.RawMessage
	if err := Decode(raw, &fields); err != nil {
		return document, err
	}
	if fields == nil {
		return document, fmt.Errorf("signed document envelope must be a JSON object")
	}
	if err := exactFields(fields, map[string]bool{"payload": true, "signature_hex": true}, map[string]bool{"payload": true, "signature_hex": true}); err != nil {
		return document, err
	}
	if err := Decode(raw, &document); err != nil {
		return document, err
	}
	if len(document.Payload) == 0 || document.SignatureHex == "" {
		return document, fmt.Errorf("signed document envelope is incomplete")
	}
	return document, nil
}
