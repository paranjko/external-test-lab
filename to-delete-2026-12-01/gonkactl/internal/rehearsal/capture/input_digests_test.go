package capture

import "testing"

func TestCloneInputDigestsIsWritableAndIndependent(t *testing.T) {
	for _, source := range []map[string]string{nil, {}, {"source_manifest": "original"}} {
		copy := cloneInputDigests(source)
		if len(copy) != len(source) {
			t.Fatal("clone changed input inventory")
		}
		for key, digest := range source {
			if copy[key] != digest {
				t.Fatal("clone changed input digest")
			}
		}
		copy["approval"] = "new"
		copy["source_manifest"] = "replacement"
		if _, exists := source["approval"]; exists {
			t.Fatal("new policy digest mutated original binding")
		}
		if source["source_manifest"] == "replacement" {
			t.Fatal("replacement policy digest mutated original binding")
		}
	}
}
