package edge

func PreserveOwnedPaths(existing []string) []string {
	out := []string{}
	for _, p := range existing {
		if p == "distribution" || p == "site" {
			out = append(out, p)
		}
	}
	return out
}
