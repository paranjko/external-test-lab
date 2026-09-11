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
	var workDir, digest, receipt, fixtureReceipt string
	flag.StringVar(&workDir, "prepared-workdir", "", "prepared fixture directory")
	flag.StringVar(&digest, "composition-digest", "", "required SHA-256 of exact prepared inputs")
	flag.StringVar(&receipt, "receipt", "", "persistent preflight receipt")
	flag.StringVar(&fixtureReceipt, "fixture-receipt", "", "required fixture evidence receipt")
	flag.Parse()
	command := flag.Args()
	if len(command) == 0 {
		fatal(errors.New("fixture launch command is required"))
	}
	if fixtureReceipt == "" {
		fatal(errors.New("fixture receipt path is required"))
	}
	decision, err := stand.PreflightComposition(workDir, digest, receipt)
	if err != nil {
		fatal(err)
	}
	if err := stand.MarkCompositionLaunch(receipt, decision); err != nil {
		fatal(err)
	}
	cmd := exec.CommandContext(context.Background(), command[0], command[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if receiptErr := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, err); receiptErr != nil {
			fatal(fmt.Errorf("record launch failure: %w", receiptErr))
		}
		fatal(err)
	}
	if err := stand.MarkCompositionFixtureResult(receipt, fixtureReceipt, decision, nil); err != nil {
		fatal(err)
	}
}

func fatal(err error) { fmt.Fprintln(os.Stderr, "m0stand:", err); os.Exit(3) }
