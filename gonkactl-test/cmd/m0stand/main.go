package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/paranjko/external-test-lab/gonkactl-test/stand"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fatal(err)
	}
}

func run(args []string) error {
	var workDir, digest, receipt, fixtureReceipt, leaseRoot, environmentID, instanceID, profilePath, compositionReceipt, invalidDigestReceipt, qualificationDecision, eligibilityReceipt string
	var preflightOnly, compatibilityOnly, qualificationVerifyOnly bool
	flags := flag.NewFlagSet("m0stand", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&workDir, "prepared-workdir", "", "prepared fixture directory")
	flags.StringVar(&digest, "composition-digest", "", "required SHA-256 of exact prepared inputs")
	flags.StringVar(&receipt, "receipt", "", "persistent preflight receipt")
	flags.StringVar(&fixtureReceipt, "fixture-receipt", "", "required fixture evidence receipt")
	flags.StringVar(&leaseRoot, "lease-root", "", "persistent root for the exclusive fixture lease")
	flags.StringVar(&environmentID, "environment-id", "", "lease environment identifier")
	flags.StringVar(&instanceID, "instance-id", "", "lease instance identifier")
	flags.StringVar(&profilePath, "profile", "", "validated M0 environment profile")
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
	cmd := exec.CommandContext(context.Background(), command[0], command[1:]...)
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
	if err := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, nil); err != nil {
		return err
	}
	return nil
}

func fatal(err error) { fmt.Fprintln(os.Stderr, "m0stand:", err); os.Exit(3) }
