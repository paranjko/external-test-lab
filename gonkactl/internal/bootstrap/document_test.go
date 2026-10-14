package bootstrap

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile("../../../bootstrap/gonka-devnet-community.json")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestRepositoryDescriptorsAndENV(t *testing.T) {
	paths, err := filepath.Glob("../../../bootstrap/*.json")
	if err != nil || len(paths) == 0 {
		t.Fatalf("inventory: %v", err)
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			doc, err := Parse(raw, nil)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(path, ".json") + ".env")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(doc.ENV(), want) {
				t.Fatalf("ENV differs: %s", doc.ENV())
			}
		})
	}
	canonical, err := os.ReadFile("../../../schema/v1.bootstrap.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonical, embeddedSchema) {
		t.Fatal("embedded schema differs from canonical schema")
	}
}

func TestRejectMalformedJSON(t *testing.T) {
	for _, raw := range [][]byte{[]byte(`{"a":1,"a":2}`), []byte(`{"a":{"b":1,"b":2}}`), []byte(`{"a":NaN}`), []byte(`{} {}`), []byte{'"', 255, '"'}, []byte(strings.Repeat("[", 130) + "0" + strings.Repeat("]", 130))} {
		var v any
		if DecodeJSON(raw, &v) == nil {
			t.Fatalf("accepted malformed input: %.100s", raw)
		}
	}
}

func TestSemanticRefusals(t *testing.T) {
	mutations := map[string]func(map[string]any){
		"duplicate node": func(d map[string]any) {
			s := d["seeds"].([]any)
			s[1].(map[string]any)["node_id"] = s[0].(map[string]any)["node_id"]
		},
		"duplicate API": func(d map[string]any) {
			s := d["seeds"].([]any)
			s[1].(map[string]any)["api"] = s[0].(map[string]any)["api"]
		},
		"out of range port": func(d map[string]any) { d["seeds"].([]any)[0].(map[string]any)["p2p"] = "tcp://node.test:65536" },
		"zero port":         func(d map[string]any) { d["seeds"].([]any)[0].(map[string]any)["p2p"] = "tcp://node.test:0" },
		"credentials": func(d map[string]any) {
			d["seeds"].([]any)[0].(map[string]any)["api"] = "https://secret:secret@node.test"
		},
		"no API": func(d map[string]any) {
			for _, s := range d["seeds"].([]any) {
				delete(s.(map[string]any), "api")
			}
		},
		"null software":  func(d map[string]any) { d["software"] = nil },
		"empty software": func(d map[string]any) { d["software"] = map[string]any{} },
		"operator mismatch": func(d map[string]any) {
			d["software"].(map[string]any)["operator_cli"].(map[string]any)["version"] = "wrong"
		},
		"duplicate compose": func(d map[string]any) {
			p := d["software"].(map[string]any)["deployment"].(map[string]any)
			files := p["compose_files"].([]any)
			f := map[string]any{"path": files[0].(map[string]any)["path"], "sha256": strings.Repeat("a", 64)}
			p["compose_files"] = append(files, f)
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			var d map[string]any
			if err := json.Unmarshal(fixture(t), &d); err != nil {
				t.Fatal(err)
			}
			mutate(d)
			raw, err := json.Marshal(d)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := Parse(raw, nil); err == nil {
				t.Fatal("invalid descriptor accepted")
			}
		})
	}
}

func TestPublishedSchemaExtensionAndRefusal(t *testing.T) {
	var schema, doc map[string]any
	if err := json.Unmarshal(embeddedSchema, &schema); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(fixture(t), &doc); err != nil {
		t.Fatal(err)
	}
	schema["properties"].(map[string]any)["extra"] = map[string]any{"type": "string"}
	doc["extra"] = "published additive extension"
	raw, _ := json.Marshal(doc)
	definition, _ := json.Marshal(schema)
	if _, err := Parse(raw, definition); err != nil {
		t.Fatal(err)
	}
	if _, err := Parse(raw, nil); err == nil {
		t.Fatal("embedded schema accepted unknown field")
	}
	schema["$ref"] = "https://untrusted.invalid/schema"
	definition, _ = json.Marshal(schema)
	if _, err := Parse(raw, definition); err == nil {
		t.Fatal("external reference accepted")
	}
}
