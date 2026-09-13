package bindings

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func selector(pkg, test string) GoTestSelector {
	return GoTestSelector{SourceRevision: "095a19b85d21aa5bae2c52d8fa2a988e52fc0a67", Module: "github.com/cucumber/godog", ModuleVersion: "v0.14.1", ModuleSum: "h1:HGZhcOyyfaKclHjJ+r/q93iaTJZLKYW6Tv3HkmUE6+M=", Package: pkg, Test: test}
}

func TestAdaptGoTestJSONKeepsOnlyAuthenticTestLevelEvents(t *testing.T) {
	input := strings.NewReader(`{"Action":"run","Package":"example/upstream","Test":"TestSmoke"}
{"Action":"pass","Package":"example/upstream","Test":"TestSmoke","Elapsed":0.125}
{"Action":"pass","Package":"example/upstream","Test":"Other"}
`)
	events, err := AdaptGoTestJSON(input, selector("example/upstream", "TestSmoke"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[1].Outcome != "pass" || events[1].ElapsedMS != 125 {
		t.Fatalf("events=%+v", events)
	}
	for _, event := range events {
		if event.StepEvidence != "unavailable" {
			t.Fatalf("invented step evidence: %+v", event)
		}
	}
}

func TestRunGoTestAuthenticPassFailAndInterruption(t *testing.T) {
	pkg := "github.com/cucumber/godog/internal/models"
	root := os.Getenv("GONKACTL_TEST_DATA_ROOT")
	pass, err := RunGoTest(context.Background(), "..", root, selector(pkg, "Test_Find/scenario"))
	if err != nil {
		t.Fatal(err)
	}
	if pass.ExitCode != 0 || terminalCount(pass.Events) != 1 {
		t.Fatalf("pass receipt=%+v", pass)
	}
	fail, err := RunGoTest(context.Background(), "..", root, selector(pkg, "Test_Find/scenario"), "-timeout=1ns")
	if err != nil {
		t.Fatal(err)
	}
	if fail.ExitCode == 0 || len(fail.Events) != 1 || fail.Events[0].Kind != "process_failed" || fail.Events[0].Outcome != "failed" {
		t.Fatalf("fail receipt=%+v", fail)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	interrupted, err := RunGoTest(ctx, "..", root, selector(pkg, "Test_Find/scenario"))
	if err != nil {
		t.Fatal(err)
	}
	if !interrupted.Interrupted || interrupted.ExitCode == 0 {
		t.Fatalf("interrupt receipt=%+v", interrupted)
	}
	for _, receipt := range []GoTestReceipt{pass, fail, interrupted} {
		if receipt.ReceiptPath == "" {
			t.Fatalf("missing persistent receipt: %+v", receipt)
		}
		if _, err := os.Stat(receipt.ReceiptPath); err != nil {
			t.Fatal(err)
		}
	}
}

func terminalCount(events []ExecutionEvent) int {
	n := 0
	for _, e := range events {
		if e.Kind == "test_finished" {
			n++
		}
	}
	return n
}

func TestAdaptGoTestJSONRejectsIncompleteSelector(t *testing.T) {
	if _, err := AdaptGoTestJSON(strings.NewReader(""), GoTestSelector{}); err == nil {
		t.Fatal("accepted incomplete selector")
	}
}
