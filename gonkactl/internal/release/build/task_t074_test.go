package build

import (
	"context"
	"testing"
)

func TestTask_T074(t *testing.T) {
	if _, e := Package(context.Background(), "/workspace", []byte(`{}`)); e != nil {
		t.Fatal(e)
	}
	if len(AssetManifest(map[string][]byte{"x": []byte("y")})["x"]) != 64 {
		t.Fatal("missing digest")
	}
}
