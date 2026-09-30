package main

import "testing"

func TestApplicationDecisionLogs(t *testing.T) {
	text := "unanchored Calculate: No majority and guardians split. Rejecting. participant=a\nStartStage:onEndOfPoCValidationStage blockHeight=306548\nCalculate: No majority and guardians split. Rejecting. participant=a guardianValidCount=0\nINF weight_pipeline addr=b before_collateral=350 final=54\nfinalized block height=306548\nCalculate: No majority and guardians split. Rejecting. participant=c\n"
	logs := parseApplicationLogs([]byte(text), "node0", "source.log", 306529, 306552)
	if len(logs) != 2 || logs[0].Height != 306548 || logs[1].Fields["final"] != "54" || logs[0].Source != "source.log:3" {
		t.Fatalf("%+v", logs)
	}
	if len(parseApplicationLogs([]byte(text), "node0", "source.log", 306550, 306552)) != 0 {
		t.Fatal("out of range evidence")
	}
}

func TestApplicationWorkerLogHeight(t *testing.T) {
	text := "OffChainValidator: filtered nodes for validation numNodes=0\nDapiStage:IsStartOfPoCValidationStage blockHeight=306544\nOffChainValidator: filtered nodes for validation numNodes=0\nSetting last processed height height=306548\nOffChainValidator: filtered nodes for validation numNodes=1\n"
	logs := parseApplicationLogs([]byte(text), "node1", "api.log", 306529, 306552)
	if len(logs) != 2 || logs[0].Height != 306544 || logs[0].Kind != "poc.worker_filter" || logs[1].Height != 306548 {
		t.Fatalf("%+v", logs)
	}
}

func TestApplicationEpochChangeKeepsExplicitAnchor(t *testing.T) {
	logs := parseApplicationLogs([]byte("StartStage:EpochGroupChanged blockHeight=50\nEpochGroupChanged\nupdating validator power power=54\n"), "node0", "core.log", 49, 52)
	if len(logs) != 1 || logs[0].Height != 50 {
		t.Fatalf("%+v", logs)
	}
}
