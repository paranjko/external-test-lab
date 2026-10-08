package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl-test/execution"
	"github.com/paranjko/external-test-lab/gonkactl-test/report"
	"github.com/paranjko/external-test-lab/gonkactl-test/stand"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	root := newRootCmd()
	root.SetArgs(os.Args[1:])
	if err := root.ExecuteContext(ctx); err != nil {
		fatal(err)
	}
}

func run(args []string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return runWithContext(ctx, args)
}

func runWithContext(ctx context.Context, args []string) error {
	var workDir, digest, receipt, fixtureReceipt, leaseRoot, environmentID, instanceID, profilePath, compositionReceipt, invalidDigestReceipt, qualificationDecision, eligibilityReceipt string
	var preflightOnly, compatibilityOnly, qualificationVerifyOnly bool
	flags := flag.NewFlagSet("gonkactl-test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&workDir, "prepared-workdir", "", "prepared fixture directory")
	flags.StringVar(&digest, "composition-digest", "", "required SHA-256 of exact prepared inputs")
	flags.StringVar(&receipt, "receipt", "", "persistent preflight receipt")
	flags.StringVar(&fixtureReceipt, "fixture-receipt", "", "required fixture evidence receipt")
	flags.StringVar(&leaseRoot, "lease-root", "", "persistent root for the exclusive fixture lease")
	flags.StringVar(&environmentID, "environment-id", "", "lease environment identifier")
	flags.StringVar(&instanceID, "instance-id", "", "lease instance identifier")
	flags.StringVar(&profilePath, "profile", "", "validated environment profile")
	flags.BoolVar(&preflightOnly, "preflight-only", false, "validate the profile and frozen composition without a lease or fixture launch")
	flags.BoolVar(&compatibilityOnly, "compatibility-only", false, "write an independent eligibility decision from retained immutable receipts")
	flags.StringVar(&compositionReceipt, "composition-receipt", "", "completed profile-bound composition receipt")
	flags.StringVar(&invalidDigestReceipt, "invalid-digest-receipt", "", "pre-launch digest-rejection receipt")
	flags.BoolVar(&qualificationVerifyOnly, "qualification-verify-only", false, "verify an externally authored qualification decision without launch")
	flags.StringVar(&qualificationDecision, "qualification-decision", "", "externally authored qualification attestation")
	flags.StringVar(&eligibilityReceipt, "eligibility-receipt", "", "frozen eligibility receipt bound by qualification-decision")
	if err := flags.Parse(args); err != nil {
		return err
	}
	command := flags.Args()
	if (preflightOnly && compatibilityOnly) || (preflightOnly && qualificationVerifyOnly) || (compatibilityOnly && qualificationVerifyOnly) {
		return errors.New("preflight-only, compatibility-only and qualification-verify-only are mutually exclusive")
	}
	if len(command) == 0 && !preflightOnly && !compatibilityOnly && !qualificationVerifyOnly {
		return errors.New("fixture launch command is required")
	}
	if fixtureReceipt == "" && !preflightOnly && !qualificationVerifyOnly {
		return errors.New("fixture receipt path is required")
	}
	if environmentID == "" || (!preflightOnly && !compatibilityOnly && !qualificationVerifyOnly && (leaseRoot == "" || instanceID == "")) {
		return errors.New("lease-root, environment-id and instance-id are required")
	}
	if profilePath == "" {
		return errors.New("profile is required")
	}
	profile, err := stand.BindProfile(profilePath)
	if err != nil {
		return fmt.Errorf("bind fixture profile: %w", err)
	}
	if environmentID != profile.EnvironmentID {
		return fmt.Errorf("environment-id %q does not match profile environment %q", environmentID, profile.EnvironmentID)
	}
	if compatibilityOnly {
		if compositionReceipt == "" || fixtureReceipt == "" || invalidDigestReceipt == "" || receipt == "" {
			return errors.New("compatibility-only requires receipt, composition-receipt, fixture-receipt and invalid-digest-receipt")
		}
		_, err := stand.EvaluateCompatibilityEligibility(profile, compositionReceipt, fixtureReceipt, invalidDigestReceipt, receipt)
		return err
	}
	if qualificationVerifyOnly {
		if qualificationDecision == "" || eligibilityReceipt == "" || receipt == "" {
			return errors.New("qualification-verify-only requires receipt, qualification-decision and eligibility-receipt")
		}
		_, err := stand.VerifyQualificationDecision(profile, qualificationDecision, eligibilityReceipt, receipt)
		return err
	}
	decision, err := stand.PreflightCompositionWithProfile(workDir, digest, receipt, profile)
	if err != nil {
		return err
	}
	if preflightOnly {
		return nil
	}
	lease, err := stand.AcquireLease(leaseRoot, environmentID, instanceID)
	if err != nil {
		return fmt.Errorf("acquire fixture lease: %w", err)
	}
	decision, err = stand.MarkCompositionLease(receipt, decision, lease, false, nil)
	if err != nil {
		_ = lease.Release()
		return err
	}
	decision, err = stand.MarkCompositionLaunch(receipt, decision)
	if err != nil {
		_ = lease.Release()
		return err
	}
	cmd := exec.CommandContext(ctx, command[0], command[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	launchErr := cmd.Run()
	releaseErr := lease.Release()
	decision, receiptErr := stand.MarkCompositionLease(receipt, decision, lease, releaseErr == nil, releaseErr)
	if receiptErr != nil {
		return fmt.Errorf("record lease release: %w", receiptErr)
	}
	if releaseErr != nil {
		if receiptErr := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, releaseErr); receiptErr != nil {
			return fmt.Errorf("record lease release failure: %w", receiptErr)
		}
		return fmt.Errorf("release fixture lease: %w", releaseErr)
	}
	if launchErr != nil {
		if receiptErr := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, launchErr); receiptErr != nil {
			return fmt.Errorf("record launch failure: %w", receiptErr)
		}
		return launchErr
	}
	return stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, nil)
}

func runReport() error {
	runID := os.Getenv("GONKACTL_TEST_RUN_ID")
	if runID == "" {
		runID = "run-" + time.Now().UTC().Format("20060102T150405.000000000Z")
	}
	root, err := filepath.Abs(outputRoot(runID))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	allureJournal, err := execution.NewAllureEventJournal(filepath.Join(root, "pilot-allure-sdk-events.jsonl"))
	if err != nil {
		return err
	}
	positiveJournal := filepath.Join(root, "pilot-events.jsonl")
	if status := execution.RunGodogPilotWithOptions(execution.PilotOptions{RunID: runID + "-positive", AttemptID: runID + "-positive-attempt", FeaturePath: filepath.Join("testdata", "feature", "pilot.feature"), JournalPath: positiveJournal, EvidenceDir: filepath.Join(root, "positive-evidence"), AllureRuntime: allureJournal}); status != 0 {
		_ = allureJournal.Close()
		return fmt.Errorf("positive pilot exited %d", status)
	}
	if err := allureJournal.Close(); err != nil {
		return err
	}
	if err := convertSelected(positiveJournal, root, runID, "qualification pilot", filepath.Join("testdata", "feature", "pilot.selection.json")); err != nil {
		return err
	}
	failureJournal := filepath.Join(root, "given-failure-events.jsonl")
	if status := execution.RunGodogPilotWithOptions(execution.PilotOptions{RunID: runID + "-negative", AttemptID: runID + "-negative-attempt", FeaturePath: filepath.Join("testdata", "feature", "failure.feature"), JournalPath: failureJournal, EvidenceDir: filepath.Join(root, "negative-evidence")}); status == 0 {
		return errors.New("negative pilot unexpectedly passed")
	}
	return convertSelected(failureJournal, root, runID, "controlled negative qualification pilot", filepath.Join("testdata", "feature", "failure.selection.json"))
}

func outputRoot(runID string) string {
	dataRoot := os.Getenv("DATA_ROOT")
	if dataRoot == "" {
		dataRoot = filepath.Join("build", "report")
	}
	return filepath.Join(dataRoot, "results", runID)
}

func convertSelected(journal, outputDir, runID, feature, selectionPath string) error {
	contents, err := os.ReadFile(selectionPath)
	if err != nil {
		return fmt.Errorf("read declared selection: %w", err)
	}
	var selected []report.SelectedCase
	if err := json.Unmarshal(contents, &selected); err != nil {
		return fmt.Errorf("decode declared selection: %w", err)
	}
	conversion, err := report.ConvertSelectedJournal(journal, outputDir, runID, feature, selected)
	if err != nil {
		return err
	}
	if len(conversion.Gaps) != 0 {
		return fmt.Errorf("selected case reconciliation produced %d gap artifact(s)", len(conversion.Gaps))
	}
	return nil
}

func fatal(err error) { fmt.Fprintln(os.Stderr, "gonkactl-test:", err); os.Exit(3) }
