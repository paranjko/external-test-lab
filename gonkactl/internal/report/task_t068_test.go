package report

import (
	"strings"
	"testing"
)

func TestTask_T068(t *testing.T) {
	if strings.Contains(Sanitize("token=SECRET"), "SECRET") {
		t.Fatal("secret leaked")
	}
	d := LatestOperationalFailure([]Diagnostic{{"report", "x", "", 9}, {"join", "failed", "", 3}})
	if d.Operation != "join" {
		t.Fatal("report failure selected")
	}
}
