package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"

	"github.com/paranjko/external-test-lab/gonkactl-test/stand"
)

func main() {
	var workDir, digest, receipt, fixtureReceipt, leaseRoot, environmentID, instanceID string
	flag.StringVar(&workDir, "prepared-workdir", "", "prepared fixture directory")
	flag.StringVar(&digest, "composition-digest", "", "required SHA-256 of exact prepared inputs")
	flag.StringVar(&receipt, "receipt", "", "persistent preflight receipt")
	flag.StringVar(&fixtureReceipt, "fixture-receipt", "", "required fixture evidence receipt")
	flag.StringVar(&leaseRoot, "lease-root", "", "persistent root for the exclusive fixture lease")
	flag.StringVar(&environmentID, "environment-id", "", "lease environment identifier")
	flag.StringVar(&instanceID, "instance-id", "", "lease instance identifier")
	flag.Parse()
	command := flag.Args()
	if len(command) == 0 {
		fatal(errors.New("fixture launch command is required"))
	}
	if fixtureReceipt == "" {
		fatal(errors.New("fixture receipt path is required"))
	}
	if leaseRoot == "" || environmentID == "" || instanceID == "" {
		fatal(errors.New("lease-root, environment-id and instance-id are required"))
	}
	decision, err := stand.PreflightComposition(workDir, digest, receipt)
	if err != nil {
		fatal(err)
	}
	lease, err := stand.AcquireLease(leaseRoot, environmentID, instanceID)
	if err != nil {
		fatal(fmt.Errorf("acquire fixture lease: %w", err))
	}
	decision, err = stand.MarkCompositionLease(receipt, decision, lease, false, nil)
	if err != nil {
		_ = lease.Release()
		fatal(err)
	}
	if err := stand.MarkCompositionLaunch(receipt, decision); err != nil {
		_ = lease.Release()
		fatal(err)
	}
	cmd := exec.CommandContext(context.Background(), command[0], command[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	launchErr := cmd.Run()
	releaseErr := lease.Release()
	decision, receiptErr := stand.MarkCompositionLease(receipt, decision, lease, releaseErr == nil, releaseErr)
	if receiptErr != nil {
		fatal(fmt.Errorf("record lease release: %w", receiptErr))
	}
	if releaseErr != nil {
		if receiptErr := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, releaseErr); receiptErr != nil {
			fatal(fmt.Errorf("record lease release failure: %w", receiptErr))
		}
		fatal(fmt.Errorf("release fixture lease: %w", releaseErr))
	}
	if launchErr != nil {
		if receiptErr := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, launchErr); receiptErr != nil {
			fatal(fmt.Errorf("record launch failure: %w", receiptErr))
		}
		fatal(launchErr)
	}
	if err := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, nil); err != nil {
		fatal(err)
	}
}

func fatal(err error) { fmt.Fprintln(os.Stderr, "m0stand:", err); os.Exit(3) }
