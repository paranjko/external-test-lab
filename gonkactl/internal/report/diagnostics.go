package report

type Diagnostic struct {
	Operation, Code, Message string
	Sequence                 int
}

func LatestOperationalFailure(values []Diagnostic) Diagnostic {
	best := Diagnostic{}
	for _, v := range values {
		if v.Operation != "report" && v.Sequence > best.Sequence {
			best = v
		}
	}
	return best
}
