package contracts

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestSemanticHistoryIDCanonicalAndSeparated(t *testing.T) {
	base := SemanticIdentityV1{"SCN-001", "contract-v1", "protocol-v3", "managed", "mock", "baseline", "history-v1"}
	got, err := base.HistoryID()
	if err != nil { t.Fatal(err) }
	canonical := []byte(`{"comparison_slot":"baseline","compute_mode":"mock","contract_revision":"contract-v1","environment_class":"managed","history_policy_revision":"history-v1","scenario_id":"SCN-001","variant_id":"protocol-v3"}`)
	sum := sha256.Sum256(canonical)
	if want := hex.EncodeToString(sum[:]); got != want { t.Fatalf("HistoryID()=%s want %s", got, want) }
	changed := base
	changed.VariantID = "protocol-v4"
	other, err := changed.HistoryID()
	if err != nil { t.Fatal(err) }
	if got == other { t.Fatal("protocol variants collided") }
}

func TestSemanticHistoryIDRejectsMissingField(t *testing.T) {
	_, err := (SemanticIdentityV1{}).HistoryID()
	if err == nil { t.Fatal("empty identity accepted") }
}

func TestValidateDAG(t *testing.T) {
	valid := []Prerequisite{{ID:"catalog"}, {ID:"session", DependsOn:[]string{"catalog"}}, {ID:"chat", DependsOn:[]string{"session"}}, {ID:"health"}}
	if err := ValidateDAG(valid); err != nil { t.Fatal(err) }
	if got := BlockedBy(valid[2], map[string]bool{"session":false}); len(got) != 1 || got[0] != "session" { t.Fatalf("BlockedBy=%v", got) }
	for name, nodes := range map[string][]Prerequisite{
		"cycle": {{ID:"a",DependsOn:[]string{"b"}}, {ID:"b",DependsOn:[]string{"a"}}},
		"unknown": {{ID:"a",DependsOn:[]string{"missing"}}},
		"duplicate": {{ID:"a"},{ID:"a"}},
	} {
		t.Run(name, func(t *testing.T) { if ValidateDAG(nodes) == nil { t.Fatal("invalid DAG accepted") } })
	}
}

func TestVerdictAndExitTable(t *testing.T) {
	tests := []struct{name string; in Completion; code int; verdict Verdict}{
		{"success",Completion{},0,VerdictPass},
		{"assertion",Completion{AssertedFailure:true},1,VerdictFail},
		{"incomplete-over-fail",Completion{IncompleteScope:true,AssertedFailure:true},2,VerdictInconclusive},
		{"operational-over-fail",Completion{OperationalError:true,AssertedFailure:true},2,VerdictBlocked},
		{"cancel-over-operational",Completion{Cancelled:true,OperationalError:true},130,VerdictInconclusive},
		{"validation-before-run",Completion{ValidationError:true,Cancelled:true},3,VerdictBlocked},
	}
	for _, tt := range tests { t.Run(tt.name, func(t *testing.T) {
		if got := tt.in.ExitCode(); got != tt.code { t.Fatalf("ExitCode=%d want %d",got,tt.code) }
		if got := tt.in.RunVerdict(); got != tt.verdict { t.Fatalf("RunVerdict=%s want %s",got,tt.verdict) }
	}) }
}
