package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const resultRef = "runtime.schema.json#/$defs/result"

type policy struct{ command, receipts string }

var resultPolicies = map[string]policy{
	"cli.help":          {command: "help", receipts: "none"},
	"cli.version":       {command: "version", receipts: "none"},
	"host.prepare":      {command: "host prepare", receipts: "required_on_complete"},
	"host.backup":       {command: "host backup", receipts: "required_on_complete"},
	"host.join.plan":    {command: "host join", receipts: "none"},
	"host.join.restore": {command: "host join", receipts: "required_on_complete"},
}

func ExecuteBuffered(ctx context.Context, capabilityID string, input json.RawMessage, handler contracts.Handler, validator contracts.Validator) contracts.Result {
	result, err := handler.Execute(ctx, input)
	if err != nil {
		return fallback(capabilityID, "internal_error")
	}
	if err := validateResult(capabilityID, result, validator); err != nil {
		return fallback(capabilityID, "handler_contract_violation")
	}
	return result
}

func RenderResult(out io.Writer, capabilityID string, result contracts.Result, validator contracts.Validator) error {
	if err := validateResult(capabilityID, result, validator); err != nil {
		return err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	_, err = out.Write(encoded)
	return err
}

func validateResult(capabilityID string, result contracts.Result, validator contracts.Validator) error {
	if isFallback(result) {
		return nil
	}
	policy, ok := resultPolicies[capabilityID]
	if !ok {
		return fmt.Errorf("unknown buffered capability %q", capabilityID)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	if err := validator.Validate(resultRef, encoded); err != nil {
		return err
	}
	if result.SchemaVersion != 1 || result.Command != policy.command {
		return fmt.Errorf("result command policy violation")
	}
	if result.Error != nil && result.Error.Code != result.Code {
		return fmt.Errorf("result error code mismatch")
	}
	if policy.receipts == "none" && len(result.Data.Receipts) != 0 {
		return fmt.Errorf("receipts forbidden")
	}
	if policy.receipts == "required_on_complete" && result.Status == "complete" && len(result.Data.Receipts) == 0 {
		return fmt.Errorf("receipt required on complete")
	}
	if capabilityID == "cli.version" && result.Data.Version == nil {
		return fmt.Errorf("version payload required")
	}
	if capabilityID == "cli.help" && result.Data.Help == nil {
		return fmt.Errorf("help payload required")
	}
	if capabilityID == "host.join.plan" && (result.Mutation != "none" || result.SignerState == "active") {
		return fmt.Errorf("plan claims mutation or signer activation")
	}
	return nil
}

func fallback(capabilityID, code string) contracts.Result {
	command := resultPolicies[capabilityID].command
	if command == "" {
		command = capabilityID
	}
	message := "Command handler violated the output contract."
	if code == "internal_error" {
		message = "Command failed unexpectedly; inspect the operation journal."
	}
	return contracts.Result{SchemaVersion: 1, Command: command, Status: "failed", Phase: "failed", Code: code, Mutation: "unknown", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: message, Retryable: false}, ExitCode: 8}
}

func isFallback(result contracts.Result) bool {
	if result.Code != "internal_error" && result.Code != "handler_contract_violation" {
		return false
	}
	return result.SchemaVersion == 1 && result.Status == "failed" && result.Phase == "failed" && result.Mutation == "unknown" && result.SignerState == "unknown" && result.ExitCode == 8 && result.Error != nil && result.Error.Code == result.Code
}
