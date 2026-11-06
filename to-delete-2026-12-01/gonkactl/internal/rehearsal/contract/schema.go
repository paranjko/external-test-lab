package contract

import (
	_ "embed"
	"encoding/json"
	"fmt"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

//go:embed protocol.schema.json
var protocolSchema []byte

// ValidateSchema checks wire shape. Semantic binding and receipt checks remain
// mandatory; this schema does not prove provenance or runtime qualification.
func ValidateSchema(kind string, value any) error {
	if kind != "binding" && kind != "receipt" {
		return fmt.Errorf("unknown rehearsal schema %q", kind)
	}
	var document any
	if err := json.Unmarshal(protocolSchema, &document); err != nil {
		return err
	}
	c := jsonschema.NewCompiler()
	const url = "https://gonka-dev.net/ctl/schemas/rehearsal-v1.json"
	if err := c.AddResource(url, document); err != nil {
		return err
	}
	s, err := c.Compile(url + "#/$defs/" + kind)
	if err != nil {
		return err
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return err
	}
	return s.Validate(generic)
}
