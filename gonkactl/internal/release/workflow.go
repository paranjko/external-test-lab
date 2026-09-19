package release

import "fmt"

type WorkflowIntent struct {
	CandidateSHA, Workflow, Token string
	DryRun                        bool
}

func (i WorkflowIntent) Validate() error {
	if i.CandidateSHA == "" || i.Workflow == "" {
		return fmt.Errorf("bound candidate and workflow required")
	}
	if !i.DryRun && i.Token == "" {
		return fmt.Errorf("explicit token required")
	}
	return nil
}
func (i WorkflowIntent) RetryAllowed(readbackFound bool) bool { return readbackFound }
