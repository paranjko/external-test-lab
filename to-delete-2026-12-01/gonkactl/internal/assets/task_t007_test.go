package assets

import (
	"bytes"
	"testing"
)

func TestTask_T007(t *testing.T) {
	manifest, err := Manifest()
	if err != nil {
		t.Fatalf("Manifest() = %v", err)
	}
	if !bytes.Contains(manifest, []byte("qwen3-0.6b.lock")) {
		t.Fatal("profile provenance is absent from manifest")
	}
	schema, err := Schema("runtime.schema.json")
	if err != nil || !bytes.Equal(schema, runtimeSchema) {
		t.Fatalf("Schema(runtime.schema.json) = %v, %v", schema, err)
	}
	schema[0] = '!'
	again, err := Schema("runtime.schema.json")
	if err != nil || again[0] == '!' {
		t.Fatalf("Schema must return a copy: %v", err)
	}
	if _, err := Schema("other.schema.json"); err == nil {
		t.Fatal("unknown schema must fail")
	}
	if err := validateBundles(manifestBytes, append([]byte("x"), runtimeTar...), profilesTar); err == nil {
		t.Fatal("corrupt archive must fail validation")
	}
}
