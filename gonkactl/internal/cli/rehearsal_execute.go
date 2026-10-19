package cli

import (
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
	"github.com/spf13/cobra"
)

// Phase adapters are application dependencies, never paths or commands supplied
// by a caller. The release registry keeps them absent until qualified.
func executeRehearsalPhase(cmd *cobra.Command, phase contract.Phase, options rehearsalOptions, dependencies RehearsalDependencies) error {
	outcome := rehearsalOutcome(phase)
	outcome.RunID = options.runID
	refuse := func(code string) error {
		outcome.Status, outcome.Code, outcome.ExitCode = "blocked", code, 2
		return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
	}
	if (phase == contract.Stage && dependencies.StageAdapter == nil) || (phase == contract.Run && dependencies.RunAdapter == nil) {
		return refuse("phase_adapter_unavailable")
	}
	if !options.apply || options.workspace == "" || options.runID == "" {
		return refuse("runtime_phase_inputs_incomplete")
	}
	run, err := session.Load(options.workspace, options.runID)
	if err != nil {
		return refuse("persisted_run_unavailable")
	}
	if options.bindingPath != "" {
		binding, readErr := readBinding(options.bindingPath)
		want, wantErr := contract.Digest(run.Binding)
		got, gotErr := contract.Digest(binding)
		if readErr != nil || wantErr != nil || gotErr != nil || want != got {
			return refuse("repeated_binding_mismatch")
		}
	}
	if err := validateRepeatedInputs(options, run.Binding, dependencies); err != nil {
		return refuse("repeated_input_mismatch")
	}
	var receipt contract.Receipt
	if phase == contract.Stage {
		receipt, err = session.ExecuteStage(cmd.Context(), options.workspace, options.runID, dependencies.StageAdapter)
	} else {
		receipt, err = session.ExecuteRun(cmd.Context(), options.workspace, options.runID, dependencies.RunAdapter)
	}
	if receipt.Operation != "" {
		outcome.Receipts = []contract.Receipt{receipt}
		outcome.Mode, outcome.Mutation = "local_runtime", "owned_workspace"
	}
	if err != nil {
		if receipt.State == contract.Unknown || errors.Is(err, session.ErrPhaseExecutionUnknown) {
			outcome.Mode, outcome.Mutation = "local_runtime", "owned_workspace"
			outcome.Status, outcome.Code, outcome.ExitCode = "unknown", "runtime_outcome_unknown", 3
			outcome.Verdict = contract.Inconclusive
			return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
		}
		return refuse("runtime_phase_refused")
	}
	if err := contract.ValidateReceipt(receipt, run.Binding); err != nil || receipt.Phase != phase || receipt.State != contract.Succeeded {
		return refuse("runtime_receipt_invalid")
	}
	outcome.Status, outcome.Code, outcome.ExitCode = "succeeded", string(phase)+"_succeeded", 0
	// Executing a phase is not a recovery PASS; verification is separate.
	outcome.Qualification = "not_verified"
	return renderRehearsal(cmd.OutOrStdout(), outcome, options.asJSON)
}
