package network

func DeduplicateObservations(observations []Observation) []Observation {
	seen := map[string]bool{}
	out := []Observation{}
	for _, o := range observations {
		key := o.NodeID + "|" + o.RemoteIP
		if !seen[key] {
			seen[key] = true
			out = append(out, o)
		}
	}
	return out
}
