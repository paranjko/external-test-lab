package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl-test/report"
	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"
)

type globalOptions struct {
	verbose bool
	format  string
	config  string
}

type runOptions struct {
	workDir, digest, receipt, fixtureReceipt, leaseRoot, environmentID, instanceID, profilePath string
	compositionReceipt, invalidDigestReceipt, qualificationDecision, eligibilityReceipt         string
	preflightOnly, compatibilityOnly, qualificationVerifyOnly                                   bool
}

func newRootCmd() *cobra.Command {
	var global globalOptions
	root := &cobra.Command{
		Use:          "gonkactl-test",
		Short:        "Run and verify Gonka test fixtures",
		Long:         "gonkactl-test executes owned fixture qualification, report generation, browser checks, and evidence transactions.",
		SilenceUsage: true,
		Args:         cobra.NoArgs,
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			if global.format != "text" && global.format != "json" {
				return fmt.Errorf("unsupported --format %q", global.format)
			}
			if global.config != "" {
				if _, err := os.Stat(global.config); err != nil {
					return fmt.Errorf("read --config: %w", err)
				}
			}
			return nil
		},
		PreRunE:  func(_ *cobra.Command, _ []string) error { return nil },
		RunE:     func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
		PostRunE: func(_ *cobra.Command, _ []string) error { return nil },
	}
	root.PersistentFlags().BoolVarP(&global.verbose, "verbose", "v", false, "enable verbose diagnostics")
	root.PersistentFlags().StringVarP(&global.format, "format", "o", "text", "output format: text or json")
	root.PersistentFlags().StringVarP(&global.config, "config", "c", os.Getenv("GONKACTL_TEST_CONFIG"), "optional configuration file")
	root.AddCommand(newRunCmd(), newReleaseCmd(), newReportCmd(), newBrowserProbeCmd(), newBrowserSmokeCmd(), newRenderTransactionCmd(), newCompletionCmd(), newDocsCmd())
	return root
}

func newRunCmd() *cobra.Command {
	var o runOptions
	cmd := &cobra.Command{
		Use:   "run <fixture-command> [arguments...]",
		Short: "Validate and launch one owned fixture",
		Long:  "Validate a profile-bound composition, acquire an owned lease, launch the fixture command, and record cleanup.",
		Args: func(_ *cobra.Command, args []string) error {
			modes := boolCount(o.preflightOnly, o.compatibilityOnly, o.qualificationVerifyOnly)
			if modes > 1 {
				return errors.New("preflight-only, compatibility-only and qualification-verify-only are mutually exclusive")
			}
			if modes == 0 && len(args) == 0 {
				return errors.New("fixture-command is required")
			}
			return nil
		},
		PreRunE: func(_ *cobra.Command, _ []string) error { return nil },
		RunE: func(cmd *cobra.Command, args []string) error {
			return runWithContext(cmd.Context(), append(runFlagArgs(o), args...))
		},
		PostRunE: func(_ *cobra.Command, _ []string) error { return nil },
	}
	f := cmd.Flags()
	f.StringVarP(&o.workDir, "prepared-workdir", "w", "", "prepared fixture directory")
	f.StringVarP(&o.digest, "composition-digest", "d", "", "SHA-256 of exact prepared inputs")
	f.StringVarP(&o.receipt, "receipt", "r", "", "persistent preflight receipt")
	f.StringVarP(&o.fixtureReceipt, "fixture-receipt", "f", "", "fixture evidence receipt")
	f.StringVarP(&o.leaseRoot, "lease-root", "l", "", "exclusive fixture lease root")
	f.StringVarP(&o.environmentID, "environment-id", "e", "", "profile environment identifier")
	f.StringVarP(&o.instanceID, "instance-id", "i", "", "fixture instance identifier")
	f.StringVarP(&o.profilePath, "profile", "p", "", "validated environment profile")
	f.BoolVarP(&o.preflightOnly, "preflight-only", "P", false, "validate without lease or launch")
	f.BoolVarP(&o.compatibilityOnly, "compatibility-only", "C", false, "write eligibility decision only")
	f.StringVar(&o.compositionReceipt, "composition-receipt", "", "completed composition receipt")
	f.StringVar(&o.invalidDigestReceipt, "invalid-digest-receipt", "", "digest-rejection receipt")
	f.BoolVarP(&o.qualificationVerifyOnly, "qualification-verify-only", "Q", false, "verify qualification without launch")
	f.StringVar(&o.qualificationDecision, "qualification-decision", "", "qualification attestation")
	f.StringVar(&o.eligibilityReceipt, "eligibility-receipt", "", "eligibility receipt")
	_ = cmd.MarkFlagRequired("receipt")
	_ = cmd.MarkFlagRequired("environment-id")
	_ = cmd.MarkFlagRequired("profile")
	_ = cmd.MarkFlagFilename("profile", "json")
	_ = cmd.MarkFlagFilename("receipt", "json")
	_ = cmd.MarkFlagFilename("fixture-receipt", "json")
	_ = cmd.RegisterFlagCompletionFunc("profile", completeJSONFiles)
	return cmd
}

func boolCount(v ...bool) int {
	n := 0
	for _, x := range v {
		if x {
			n++
		}
	}
	return n
}
func runFlagArgs(o runOptions) []string {
	a := []string{"--prepared-workdir", o.workDir, "--composition-digest", o.digest, "--receipt", o.receipt, "--fixture-receipt", o.fixtureReceipt, "--lease-root", o.leaseRoot, "--environment-id", o.environmentID, "--instance-id", o.instanceID, "--profile", o.profilePath, "--composition-receipt", o.compositionReceipt, "--invalid-digest-receipt", o.invalidDigestReceipt, "--qualification-decision", o.qualificationDecision, "--eligibility-receipt", o.eligibilityReceipt}
	if o.preflightOnly {
		a = append(a, "--preflight-only")
	}
	if o.compatibilityOnly {
		a = append(a, "--compatibility-only")
	}
	if o.qualificationVerifyOnly {
		a = append(a, "--qualification-verify-only")
	}
	return a
}

func newReportCmd() *cobra.Command {
	return simpleCmd("report", "Generate report inputs", "Generate positive and controlled-negative Allure result inputs.", cobra.NoArgs, func(context.Context, []string) error { return runReport() })
}

func newReleaseCmd() *cobra.Command {
	o := releaseOptions{
		Tag:      os.Getenv("RELEASE_TAG"),
		SHA256:   os.Getenv("RELEASE_SHA256"),
		Features: os.Getenv("FEATURES"),
		DataRoot: os.Getenv("DATA_ROOT"),
	}
	cmd := &cobra.Command{
		Use:     "release",
		Short:   "Test a pinned DevShard release against local feature scenarios",
		Long:    "Verify the official release archive, run supported feature bindings in an owned fixture, and write a per-scenario report. Unbound scenarios remain not_run.",
		Args:    cobra.NoArgs,
		PreRunE: func(_ *cobra.Command, _ []string) error { return nil },
		RunE: func(cmd *cobra.Command, _ []string) error {
			directory, err := executeRelease(cmd.Context(), o)
			if directory != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "Report: %s\n", filepath.Join(directory, "index.html"))
				fmt.Fprintf(cmd.OutOrStdout(), "Results: %s\n", filepath.Join(directory, "report.json"))
			}
			return err
		},
		PostRunE: func(_ *cobra.Command, _ []string) error { return nil },
	}
	f := cmd.Flags()
	f.StringVarP(&o.Tag, "release-tag", "t", o.Tag, "release tag (or RELEASE_TAG)")
	f.StringVarP(&o.SHA256, "release-sha256", "s", o.SHA256, "official archive SHA-256 (or RELEASE_SHA256)")
	f.StringVarP(&o.Features, "features", "f", o.Features, "feature directory or file (default: ./feature; or FEATURES)")
	f.StringVarP(&o.DataRoot, "data-root", "d", o.DataRoot, "report root (default: ./build/report; or DATA_ROOT)")
	f.StringVarP(&o.Archive, "archive", "a", "", "optional local release archive for offline use")
	f.StringVarP(&o.Source, "source", "S", "", "optional local checkout at the release commit for offline use")
	_ = cmd.MarkFlagFilename("features", "feature")
	_ = cmd.MarkFlagFilename("archive", "zip")
	return cmd
}
func newBrowserProbeCmd() *cobra.Command {
	return simpleCmd("browser-probe <data-root>", "Probe host Chrome", "Create an owned browser profile and verify Chrome CDP availability.", cobra.ExactArgs(1), func(ctx context.Context, a []string) error { return report.BrowserProbe(ctx, a[0]) })
}
func newBrowserSmokeCmd() *cobra.Command {
	return simpleCmd("browser-smoke <data-root> <run-id> [report-root]", "Verify a rendered report in Chrome", "Serve a rendered report locally and run CDP assertions.", cobra.RangeArgs(2, 3), func(ctx context.Context, a []string) error {
		root := ""
		if len(a) == 3 {
			root = a[2]
		}
		return report.BrowserSmoke(ctx, a[0], a[1], root)
	})
}
func newRenderTransactionCmd() *cobra.Command {
	return simpleCmd("render-transaction <data-root> <run-id>", "Render and append report history", "Render Allure results and atomically append one history point.", cobra.ExactArgs(2), func(ctx context.Context, a []string) error { return report.RenderTransaction(ctx, a[0], a[1]) })
}

func simpleCmd(use, short, long string, args cobra.PositionalArgs, fn func(context.Context, []string) error) *cobra.Command {
	return &cobra.Command{Use: use, Short: short, Long: long, Args: args, PreRunE: func(*cobra.Command, []string) error { return nil }, RunE: func(cmd *cobra.Command, a []string) error { return fn(cmd.Context(), a) }, PostRunE: func(*cobra.Command, []string) error { return nil }}
}

func newCompletionCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "completion <bash|zsh|fish|powershell>", Short: "Generate shell completion", Long: "Generate shell completion for Bash, Zsh, Fish, or PowerShell.", Args: cobra.ExactArgs(1), ValidArgs: []string{"bash", "zsh", "fish", "powershell"}, ValidArgsFunction: func(*cobra.Command, []string, string) ([]string, cobra.ShellCompDirective) {
		return []string{"bash", "zsh", "fish", "powershell"}, cobra.ShellCompDirectiveNoFileComp
	}, PreRunE: func(*cobra.Command, []string) error { return nil }, RunE: func(cmd *cobra.Command, a []string) error {
		switch a[0] {
		case "bash":
			return cmd.Root().GenBashCompletion(os.Stdout)
		case "zsh":
			return cmd.Root().GenZshCompletion(os.Stdout)
		case "fish":
			return cmd.Root().GenFishCompletion(os.Stdout, true)
		case "powershell":
			return cmd.Root().GenPowerShellCompletion(os.Stdout)
		}
		return errors.New("unsupported shell")
	}, PostRunE: func(*cobra.Command, []string) error { return nil }}
	return cmd
}

func newDocsCmd() *cobra.Command {
	return simpleCmd("docs <directory>", "Generate CLI Markdown documentation", "Generate Markdown documentation from the current Cobra command tree.", cobra.ExactArgs(1), func(_ context.Context, a []string) error {
		if err := os.MkdirAll(a[0], 0o755); err != nil {
			return err
		}
		return doc.GenMarkdownTree(newRootCmd(), a[0])
	})
}

func completeJSONFiles(_ *cobra.Command, _ []string, prefix string) ([]string, cobra.ShellCompDirective) {
	matches, _ := filepath.Glob(prefix + "*.json")
	return matches, cobra.ShellCompDirectiveDefault
}
