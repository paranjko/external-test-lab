package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRedactSourceJSON(t *testing.T) {
	b := redactSource([]byte(`{"kb_per_input_token":{"value":"1","exponent":-4},"private_key":{"value":"hidden"},"nested":[{"password":"hidden"}],"height":9007199254740993}`))
	if !json.Valid(b) || strings.Contains(string(b), "hidden") || !strings.Contains(string(b), "9007199254740993") || !strings.Contains(string(b), `"exponent":-4`) {
		t.Fatal(string(b))
	}
}
