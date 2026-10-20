package driver

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
)

func observationFixture(t *testing.T) (*Coordinator, *fakeDocker, *fakeHooks, *memoryJournal) {
	t.Helper()
	c, docker, hooks, journal, plan, _ := driverFixture(t, true)
	plan.HPlusOne.BlockID, plan.HPlusOne.PartSetHash, plan.HPlusOne.PartSetTotal = "", "", 0
	docker.plan, hooks.plan = plan, plan
	c, err := newCoordinator(plan, c.runtime, docker, "/usr/bin/docker", journal, hooks)
	if err != nil {
		t.Fatalf("future H+1 identity must not be a launch prerequisite: %v", err)
	}
	return c, docker, hooks, journal
}

func TestHPlusOneObservedAfterLaunchPersistsAcrossReopen(t *testing.T) {
	c, docker, hooks, _ := observationFixture(t)
	ctx := context.Background()
	journal, err := OpenFSJournal(c.binding)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = journal.Close() })
	openCoordinator := func() *Coordinator {
		t.Helper()
		runtime, err := isolation.NewRuntimeAdapter(docker, "/usr/bin/docker", c.binding, journal)
		if err != nil {
			t.Fatal(err)
		}
		out, err := newCoordinator(c.plan, runtime, docker, "/usr/bin/docker", journal, hooks)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	c = openCoordinator()
	raw := hooks.hplusRaw
	hooks.hplusRaw = nil
	if err := c.RunThrough(ctx, StandardHandoffValidated); err != nil {
		t.Fatalf("standard launch required future evidence: %v", err)
	}
	if !hooks.standardReady || strings.Contains(strings.Join(hooks.events, ","), "hplus1") {
		t.Fatalf("H+1 collection preceded standard handoff: %v", hooks.events)
	}
	journalBytes, err := os.ReadFile(filepath.Join(c.binding.Workspace, fsJournalName))
	if err != nil {
		t.Fatal(err)
	}
	launchIntentFound := false
	for _, line := range strings.Split(strings.TrimSpace(string(journalBytes)), "\n") {
		var event fsEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		if event.Step == StandardStart && event.Kind == "begin" {
			var launch standardStartReceipt
			if err := contract.DecodeStrict(event.Evidence, &launch); err != nil || launch.Continuity != c.plan.HPlusOne || launch.BlockPartSize != c.plan.BlockPartSize {
				t.Fatalf("launch intent lacks known continuity requirements: %+v %v", launch, err)
			}
			launchIntentFound = true
		}
	}
	if !launchIntentFound {
		t.Fatal("standard launch continuity was not durably recorded in intent")
	}
	if _, err := c.Run(ctx); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("missing post-launch bytes accepted: %v", err)
	}
	hooks.hplusRaw = raw
	first, err := c.Run(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := journal.Read(ctx, c.bindingDigest)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := findEvidence[hplusReceipt](ledger, HPlusOneCollected)
	if err != nil || stored.Verification != first.HPlusOne || !reflect.DeepEqual(stored.Evidence.Raw, raw) || first.HPlusOne.SHA256 != contract.PayloadDigest(raw) || first.HPlusOne.Block.BlockID == "" || first.HPlusOne.Block.PartSetHash == "" || first.HPlusOne.Block.PartSetTotal == 0 {
		t.Fatalf("observed identity/raw bytes not pinned: %+v, %v", stored, err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	journal, err = OpenFSJournal(c.binding)
	if err != nil {
		t.Fatal(err)
	}
	c = openCoordinator()
	hooks.hplusRaw = []byte("replacement must never be requested")
	events := len(hooks.events)
	second, err := c.Run(ctx)
	if err != nil || second.HPlusOne != first.HPlusOne || len(hooks.events) != events {
		t.Fatalf("reopen replaced durable observation: %+v %v, hooks=%v", second, err, hooks.events)
	}
	for _, operation := range []string{"start:control-old", "start:recovery-node", "kill:recovery-node", "start:standard-node"} {
		count := 0
		for _, got := range docker.ops {
			if got == operation {
				count++
			}
		}
		if count != 1 {
			t.Fatalf("reopen repeated %s: %v", operation, docker.ops)
		}
	}
}

func TestObservedHPlusOneRejectsBrokenContinuity(t *testing.T) {
	cases := map[string]func(*cmtproto.Block){
		"height":              func(b *cmtproto.Block) { b.Header.Height++ },
		"chain":               func(b *cmtproto.Block) { b.Header.ChainID = "other-chain" },
		"previous block":      func(b *cmtproto.Block) { b.Header.LastBlockId.Hash[0] ^= 1 },
		"previous part hash":  func(b *cmtproto.Block) { b.Header.LastBlockId.PartSetHeader.Hash[0] ^= 1 },
		"previous part total": func(b *cmtproto.Block) { b.Header.LastBlockId.PartSetHeader.Total++ },
		"app hash":            func(b *cmtproto.Block) { b.Header.AppHash[0] ^= 1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			c, _, hooks, journal := observationFixture(t)
			var block cmtproto.Block
			if err := proto.Unmarshal(hooks.hplusRaw, &block); err != nil {
				t.Fatal(err)
			}
			mutate(&block)
			raw, err := proto.Marshal(&block)
			if err != nil {
				t.Fatal(err)
			}
			hooks.hplusRaw = raw
			if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) {
				t.Fatalf("bad continuity accepted: %v", err)
			}
			if !hooks.standardReady || stepComplete(journal.ledger, HPlusOneCollected) {
				t.Fatal("invalid H+1 was not rejected after handoff and before persistence")
			}
		})
	}
}

func TestHPlusOnePlanRejectsPartialIdentityAndUnboundContinuity(t *testing.T) {
	c, _, _, _ := observationFixture(t)
	cases := map[string]func(*Plan){
		"only block hash":     func(p *Plan) { p.HPlusOne.BlockID = strings.Repeat("a", 64) },
		"only part hash":      func(p *Plan) { p.HPlusOne.PartSetHash = strings.Repeat("a", 64) },
		"only part count":     func(p *Plan) { p.HPlusOne.PartSetTotal = 1 },
		"height":              func(p *Plan) { p.HPlusOne.Height++ },
		"chain":               func(p *Plan) { p.HPlusOne.ChainID = "other" },
		"previous block":      func(p *Plan) { p.HPlusOne.PreviousBlockID = strings.Repeat("a", 64) },
		"previous part hash":  func(p *Plan) { p.HPlusOne.PreviousPartSetHash = strings.Repeat("a", 64) },
		"previous part count": func(p *Plan) { p.HPlusOne.PreviousPartSetTotal++ },
		"app hash":            func(p *Plan) { p.HPlusOne.HeaderAppHash = strings.Repeat("a", 64) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			plan := c.plan
			mutate(&plan)
			if validatePlan(plan) == nil {
				t.Fatal("invalid pre-launch binding accepted")
			}
		})
	}
}

func TestHPlusOneResumeRejectsSubstitutedReceipt(t *testing.T) {
	cases := map[string]func(*hplusReceipt){
		"raw":      func(r *hplusReceipt) { r.Evidence.Raw[0] ^= 1 },
		"digest":   func(r *hplusReceipt) { r.Evidence.RawSHA256 = strings.Repeat("a", 64) },
		"identity": func(r *hplusReceipt) { r.Verification.Block.BlockID = strings.Repeat("a", 64) },
		"part set": func(r *hplusReceipt) { r.Verification.Block.PartSetHash = strings.Repeat("a", 64) },
		"runtime":  func(r *hplusReceipt) { r.Evidence.RuntimeID = "other" },
		"run":      func(r *hplusReceipt) { r.Evidence.RunID = "other" },
		"binding":  func(r *hplusReceipt) { r.Evidence.BindingDigest = strings.Repeat("a", 64) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			c, docker, _, journal := observationFixture(t)
			if _, err := c.Run(context.Background()); err != nil {
				t.Fatal(err)
			}
			stored, err := findEvidence[hplusReceipt](journal.ledger, HPlusOneCollected)
			if err != nil {
				t.Fatal(err)
			}
			mutate(&stored)
			raw, err := json.Marshal(stored)
			if err != nil {
				t.Fatal(err)
			}
			journal.ledger.Completed[len(orderedSteps)-1].Evidence = raw
			operations := len(docker.ops)
			if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) || len(docker.ops) != operations {
				t.Fatalf("substituted persisted evidence accepted or reached runtime: %v", err)
			}
		})
	}
}

func TestHPlusOnePinnedIdentityStillRejectsReplacement(t *testing.T) {
	c, _, _, _, _, _ := driverFixture(t, true)
	c.plan.HPlusOne.BlockID = strings.Repeat("a", 64)
	if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) {
		t.Fatalf("changed explicitly pinned H+1 accepted: %v", err)
	}
}

func TestHPlusOneResumeRejectsChangedLaunchRequirements(t *testing.T) {
	for _, field := range []string{"app hash", "part size", "missing legacy receipt"} {
		t.Run(field, func(t *testing.T) {
			c, docker, _, journal := observationFixture(t)
			if err := c.RunThrough(context.Background(), StandardHandoffValidated); err != nil {
				t.Fatal(err)
			}
			switch field {
			case "app hash":
				c.plan.HPlusOne.HeaderAppHash = strings.Repeat("a", 64)
			case "part size":
				c.plan.BlockPartSize++
			case "missing legacy receipt":
				for i := range journal.ledger.Completed {
					if journal.ledger.Completed[i].Step == StandardStart {
						journal.ledger.Completed[i].Evidence = json.RawMessage(`null`)
					}
				}
			}
			operations := len(docker.ops)
			if _, err := c.Run(context.Background()); !errors.Is(err, ErrPrecondition) || len(docker.ops) != operations {
				t.Fatalf("changed launch requirements accepted or reached runtime: %v", err)
			}
		})
	}
}
