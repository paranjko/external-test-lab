package contracts

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func TestSchemasV1Fixtures(t *testing.T) {
	schemas, err := filepath.Glob("schemas/*.schema.json")
	if err != nil || len(schemas) != 6 {
		t.Fatalf("schemas=%v err=%v", schemas, err)
	}
	for _, schemaPath := range schemas {
		name := filepath.Base(schemaPath[:len(schemaPath)-len(".schema.json")])
		t.Run(name, func(t *testing.T) {
			compiler := jsonschema.NewCompiler()
			compiler.AssertFormat()
			schema, err := compiler.Compile(schemaPath)
			if err != nil { t.Fatalf("compile: %v", err) }
			for _, tc := range []struct { path string; wantValid bool }{
				{filepath.Join("testdata", name+".valid.json"), true},
				{filepath.Join("testdata", name+".invalid.json"), false},
			} {
				file, err := os.Open(tc.path)
				if err != nil { t.Fatal(err) }
				value, err := jsonschema.UnmarshalJSON(file)
				file.Close()
				if err != nil { t.Fatalf("decode %s: %v", tc.path, err) }
				err = schema.Validate(value)
				if (err == nil) != tc.wantValid { t.Fatalf("%s valid=%t, err=%v", tc.path, err == nil, err) }
			}
		})
	}
}
