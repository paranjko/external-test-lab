package edge

import "testing"

func TestTask_T044(t *testing.T) {
	if ValidateRoutes([]Route{{"public", "/", "http://127.0.0.1:8080"}}) != nil {
		t.Fatal("valid route refused")
	}
	if ValidateRoutes([]Route{{"public", "/", "https://external"}}) == nil {
		t.Fatal("external upstream accepted")
	}
	if len(PreserveOwnedPaths([]string{"distribution", "site", "other"})) != 2 {
		t.Fatal("owned paths lost")
	}
}
