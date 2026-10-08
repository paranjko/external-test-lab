package artifact

import "testing"

func TestTask_T017(t *testing.T) {
	m := ReleaseMetadata{Tag: "release/v1.2.3", Commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Available: true, Assets: []ReleaseAsset{{"inferenced-linux-amd64.zip", "https://example/a", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}
	if _, e := ResolveRelease(m, "1.2.3", "inferenced-linux-amd64.zip"); e != nil {
		t.Fatal(e)
	}
	m.Malformed = true
	m.Available = false
	if _, e := SelectPrimaryOrMirror(m, m, "1.2.3", "inferenced-linux-amd64.zip"); e == nil {
		t.Fatal("malformed primary fell back")
	}
}
