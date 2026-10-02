package join

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"testing"
)

func TestTask_T018(t *testing.T) {
	bad, _ := json.Marshal(PlanInput{Release: "old"})
	r, _ := NewReadOnlyJoinPlanningHandler(contracts.Dependencies{}).Execute(context.Background(), bad)
	if r.Code != "invalid_join_plan_input" {
		t.Fatal(r.Code)
	}
	good, _ := json.Marshal(PlanInput{Home: "/var/lib/gonkactl"})
	r, _ = NewReadOnlyJoinPlanningHandler(contracts.Dependencies{}).Execute(context.Background(), good)
	if r.Code != "join_plan" || !r.Data.RequiresQualification {
		t.Fatalf("%#v", r)
	}
}
