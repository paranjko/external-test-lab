package contracts

type Verdict string

const (
	VerdictPass         Verdict = "PASS"
	VerdictFail         Verdict = "FAIL"
	VerdictBlocked      Verdict = "BLOCKED"
	VerdictInconclusive Verdict = "INCONCLUSIVE"
)

type Completion struct {
	ValidationError bool
	Cancelled       bool
	OperationalError bool
	IncompleteScope bool
	AssertedFailure bool
}

// ExitCode implements the fixed MVP priority table in section 6.3.
func (c Completion) ExitCode() int {
	if c.ValidationError {
		return 3
	}
	if c.Cancelled {
		return 130
	}
	if c.OperationalError || c.IncompleteScope {
		return 2
	}
	if c.AssertedFailure {
		return 1
	}
	return 0
}

// RunVerdict keeps environment/precondition failure separate from a tested
// invariant failure, and missing evidence separate from both.
func (c Completion) RunVerdict() Verdict {
	if c.ValidationError {
		return VerdictBlocked
	}
	if c.Cancelled || c.IncompleteScope {
		return VerdictInconclusive
	}
	if c.OperationalError {
		return VerdictBlocked
	}
	if c.AssertedFailure {
		return VerdictFail
	}
	return VerdictPass
}
