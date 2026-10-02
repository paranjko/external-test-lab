package network

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// rejectDuplicateKeys rejects duplicate object keys recursively before typed decoding.
func rejectDuplicateKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var walk func() error
	walk = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		switch token.(type) {
		case json.Delim:
			d := token.(json.Delim)
			if d == '{' {
				seen := map[string]bool{}
				for decoder.More() {
					key, err := decoder.Token()
					if err != nil {
						return err
					}
					name, ok := key.(string)
					if !ok || seen[name] {
						return fmt.Errorf("duplicate bootstrap key %q", name)
					}
					seen[name] = true
					if err := walk(); err != nil {
						return err
					}
				}
				_, err = decoder.Token()
				return err
			}
			if d == '[' {
				for decoder.More() {
					if err := walk(); err != nil {
						return err
					}
				}
				_, err = decoder.Token()
				return err
			}
		}
		return nil
	}
	if err := walk(); err != nil {
		return err
	}
	if decoder.More() {
		return fmt.Errorf("bootstrap has trailing document")
	}
	return nil
}
