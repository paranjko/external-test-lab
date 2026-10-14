package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/bootstrap"
	"github.com/spf13/cobra"
)

type ExitError struct {
	Code int
	Err  error
}

func (e *ExitError) Error() string { return e.Err.Error() }
func (e *ExitError) Unwrap() error { return e.Err }

func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var coded *ExitError
	if errors.As(err, &coded) {
		return coded.Code
	}
	return 2
}

func newBootstrapCommand() *cobra.Command {
	command := &cobra.Command{Use: "bootstrap", Short: "maintain public network bootstrap documents"}
	var options bootstrap.ValidateOptions
	var asJSON bool
	var timeout time.Duration
	validate := &cobra.Command{
		Use: "validate <chain_id>", Short: "validate bootstrap files, every seed, and declared images",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			options.ChainID = args[0]
			if timeout <= 0 || timeout > time.Minute {
				return &ExitError{2, fmt.Errorf("timeout must be positive and at most 1m")}
			}
			transport := bootstrap.NewTransport()
			transport.Timeout = timeout
			ctx, cancel := context.WithTimeout(cmd.Context(), 15*time.Minute)
			defer cancel()
			report, err := transport.Validate(ctx, options)
			if err != nil {
				return &ExitError{2, err}
			}
			if asJSON {
				encoder := json.NewEncoder(cmd.OutOrStdout())
				encoder.SetIndent("", "  ")
				if err := encoder.Encode(report); err != nil {
					return &ExitError{2, err}
				}
			} else {
				for _, result := range report.Results {
					verdict := "FAIL"
					if result.OK {
						verdict = "PASS"
					}
					fmt.Fprintf(cmd.OutOrStdout(), "%s %s\n", verdict, result.ChainID)
					fmt.Fprintf(cmd.OutOrStdout(), "  policy: %s\n", result.Policy)
					for _, warning := range result.Warnings {
						fmt.Fprintf(cmd.OutOrStdout(), "  warning: %s\n", warning)
					}
					for _, check := range result.Checks {
						if !check.OK {
							fmt.Fprintf(cmd.OutOrStdout(), "  %s: %s: %s\n", check.Stage, check.URL, check.Error)
						}
					}
					if result.SoftwareDeclared != nil && !*result.SoftwareDeclared {
						fmt.Fprintln(cmd.OutOrStdout(), "  images: not applicable (software not declared)")
					}
				}
			}
			for _, result := range report.Results {
				if !result.OK {
					return &ExitError{1, fmt.Errorf("bootstrap validation failed")}
				}
			}
			return nil
		},
	}
	validate.Flags().StringVar(&options.Policy, "policy", "auto", "network policy: auto, strict, testnet or devnet")
	validate.Flags().StringVar(&options.Directory, "path", "", "validate a local JSON/ENV pair instead of publication")
	validate.Flags().StringVar(&options.ExpectedDirectory, "compare-published", "", "compare published JSON/ENV bytes with this directory")
	validate.Flags().StringVar(&options.BaseURL, "base-url", "https://gonka-dev.net", "bootstrap publication origin")
	validate.Flags().DurationVar(&timeout, "timeout", 10*time.Second, "per-request timeout (maximum 1m)")
	validate.Flags().BoolVar(&asJSON, "json", false, "emit a structured report, including failed checks")
	command.AddCommand(validate)
	command.AddCommand(newBootstrapUpdateCommand())
	return command
}

func newBootstrapUpdateCommand() *cobra.Command {
	var options bootstrap.UpdateOptions
	var asJSON bool
	var timeout time.Duration
	command := &cobra.Command{
		Use:   "update <chain_id> <output_dir> [path_profile]",
		Short: "discover and validate seeds before replacing local bootstrap files",
		Args:  cobra.RangeArgs(2, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			options.ChainID, options.Directory, options.Profile = args[0], args[1], ""
			if len(args) == 3 {
				options.Profile = args[2]
			}
			if timeout <= 0 || timeout > time.Minute {
				return &ExitError{2, fmt.Errorf("timeout must be positive and at most 1m")}
			}
			transport := bootstrap.NewTransport()
			transport.Timeout = timeout
			ctx, cancel := context.WithTimeout(cmd.Context(), 15*time.Minute)
			defer cancel()
			report, err := transport.Update(ctx, options)
			if err != nil {
				return &ExitError{2, err}
			}
			if asJSON {
				encoder := json.NewEncoder(cmd.OutOrStdout())
				encoder.SetIndent("", "  ")
				if err := encoder.Encode(report); err != nil {
					return &ExitError{2, err}
				}
			} else {
				for _, result := range report.Results {
					verdict := "FAIL"
					if result.OK {
						verdict = "UNCHANGED"
						if report.Changed {
							verdict = "UPDATED"
						}
					}
					fmt.Fprintf(cmd.OutOrStdout(), "%s %s\n", verdict, result.ChainID)
					fmt.Fprintf(cmd.OutOrStdout(), "  policy: %s\n", result.Policy)
					for _, warning := range result.Warnings {
						fmt.Fprintf(cmd.OutOrStdout(), "  warning: %s\n", warning)
					}
					for _, check := range result.Checks {
						if !check.OK {
							fmt.Fprintf(cmd.OutOrStdout(), "  %s: %s: %s\n", check.Stage, check.URL, check.Error)
						}
					}
				}
			}
			for _, result := range report.Results {
				if !result.OK {
					return &ExitError{1, fmt.Errorf("bootstrap update failed")}
				}
			}
			return nil
		},
	}
	command.Flags().StringVar(&options.Policy, "policy", "auto", "update policy: auto, strict, testnet or devnet")
	command.Flags().StringVar(&options.BaseURL, "base-url", "https://gonka-dev.net", "bootstrap publication origin used when creating files")
	command.Flags().DurationVar(&timeout, "timeout", 10*time.Second, "per-request timeout (maximum 1m)")
	command.Flags().BoolVar(&asJSON, "json", false, "emit a structured report, including failed checks")
	return command
}
