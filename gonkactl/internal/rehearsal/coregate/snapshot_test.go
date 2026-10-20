package coregate

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

type fixtureKV struct {
	Store string `json:"store"`
	Key   []byte `json:"key_base64"`
	Value []byte `json:"value_base64"`
}

func makeAppDumpFixture(t *testing.T, dir string, records []fixtureKV, inventory []inspectorStoreInventory) []byte {
	t.Helper()
	var dump []byte
	counts := make(map[string]uint64)
	logical := make(map[string]uint64)
	for _, item := range records {
		keyHash := sha256.Sum256(item.Key)
		valueHash := sha256.Sum256(item.Value)
		line, err := json.Marshal(appDumpRecord{
			Store: item.Store, KeyBase64: base64.StdEncoding.EncodeToString(item.Key), ValueBase64: base64.StdEncoding.EncodeToString(item.Value),
			KeySHA256: hex.EncodeToString(keyHash[:]), ValueSHA256: hex.EncodeToString(valueHash[:]),
		})
		if err != nil {
			t.Fatal(err)
		}
		dump = append(dump, line...)
		dump = append(dump, '\n')
		counts[item.Store]++
		logical[item.Store] += uint64(len(item.Key) + len(item.Value))
	}
	for i := range inventory {
		inventory[i].KVCount = counts[inventory[i].Name]
		inventory[i].LogicalBytes = logical[inventory[i].Name]
	}
	dumpHash := sha256.Sum256(dump)
	stores, err := json.Marshal(inventory)
	if err != nil {
		t.Fatal(err)
	}
	summary := fmt.Sprintf(`{"kv_dump_file":"app-kv.jsonl","kv_dump_sha256":%q,"kv_dump_record_count":%d,"kv_dump_logical_bytes":%d,"stores":%s,"ignored_actual_inspector_field":"forward-compatible"}`, hex.EncodeToString(dumpHash[:]), len(records), sumLogical(logical), stores)
	if err := os.WriteFile(dir+"/summary.json", []byte(summary), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/app-kv.jsonl", dump, 0600); err != nil {
		t.Fatal(err)
	}
	return dump
}

func sumLogical(values map[string]uint64) uint64 {
	var total uint64
	for _, value := range values {
		total += value
	}
	return total
}

func snapshotReader(t *testing.T, dir string, limits Limits, pins map[string]string) *FileEvidenceReader {
	t.Helper()
	r, err := NewFileEvidenceReader(LocalProvenance{RunID: "local-only", BindingDigest: strings.Repeat("a", 64), Nodes: map[string]string{"node": dir}, SourceDigests: map[string]map[string]string{"node": pins}}, limits)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestReadApplicationSnapshotPreservesBinaryAndInventoryEmptyStore(t *testing.T) {
	dir := t.TempDir()
	dump := makeAppDumpFixture(t, dir, []fixtureKV{{Store: "alpha", Key: []byte{0, 0xff, 0x10}, Value: []byte{}}, {Store: "alpha", Key: []byte("k\x00"), Value: []byte{0xfe, 0x01}}}, []inspectorStoreInventory{{Name: "alpha"}, {Name: "empty"}})
	r := snapshotReader(t, dir, Limits{}, nil)
	snapshot, summary, gotDump, summaryDigest, dumpDigest, err := r.ReadApplicationSnapshot("node")
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Stores) != 2 || snapshot.Stores[0].Name != "alpha" || len(snapshot.Stores[0].Entries) != 2 || snapshot.Stores[1].Name != "empty" || len(snapshot.Stores[1].Entries) != 0 {
		t.Fatalf("inventory/entries were not preserved: %+v", snapshot)
	}
	if got := snapshot.Stores[0].Entries; string(got[0].Key) != string([]byte{0, 0xff, 0x10}) || got[0].Value == nil || len(got[0].Value) != 0 || string(got[1].Value) != string([]byte{0xfe, 0x01}) {
		t.Fatalf("byte keys or empty value changed: %#v", got)
	}
	if len(summary) == 0 || string(gotDump) != string(dump) || summaryDigest.Size != int64(len(summary)) || dumpDigest.SHA256 == "" {
		t.Fatal("raw source bytes or independent digests were not returned")
	}
}

func TestReadApplicationSnapshotRejectsTamperTruncationAndInventoryMismatch(t *testing.T) {
	t.Run("record value digest", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
		dump, _ := os.ReadFile(dir + "/app-kv.jsonl")
		var record appDumpRecord
		if err := json.Unmarshal(dump[:len(dump)-1], &record); err != nil {
			t.Fatal(err)
		}
		record.ValueSHA256 = strings.Repeat("0", 64)
		tampered, _ := json.Marshal(record)
		_ = os.WriteFile(dir+"/app-kv.jsonl", append(tampered, '\n'), 0600)
		rewriteSummaryDumpSHA(t, dir)
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "key/value digest") {
			t.Fatalf("expected decoded record digest rejection, got %v", err)
		}
	})
	t.Run("unterminated record", func(t *testing.T) {
		dir := t.TempDir()
		dump := makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
		_ = os.WriteFile(dir+"/app-kv.jsonl", dump[:len(dump)-1], 0600)
		// The independently computed SHA must match the altered bytes first.
		rewriteSummaryDumpSHA(t, dir)
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "unterminated") {
			t.Fatalf("expected truncation rejection, got %v", err)
		}
	})
	t.Run("retains empty store", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}, {Name: "empty"}})
		if _, err := os.Stat(dir + "/summary.json"); err != nil {
			t.Fatal(err)
		}
		// Inventory is the source of truth for store presence, including zero-entry stores.
		s, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node")
		if err != nil || len(s.Stores) != 2 || s.Stores[1].Name != "empty" {
			t.Fatalf("empty inventory store lost: %+v, %v", s, err)
		}
	})
	t.Run("store count mismatch", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
		writeSummaryStoreCount(t, dir, 2)
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "count for store") {
			t.Fatalf("expected store inventory mismatch, got %v", err)
		}
	})
	t.Run("duplicate key", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("same"), Value: []byte("1")}, {Store: "s", Key: []byte("same"), Value: []byte("2")}}, []inspectorStoreInventory{{Name: "s"}})
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "duplicate key") {
			t.Fatalf("expected duplicate key rejection, got %v", err)
		}
	})
	t.Run("record outside inventory", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
		mutateFirstRecord(t, dir, func(record *appDumpRecord) { record.Store = "not-in-inventory" })
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "absent from inventory") {
			t.Fatalf("expected inventory membership rejection, got %v", err)
		}
	})
	t.Run("invalid base64", func(t *testing.T) {
		dir := t.TempDir()
		makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
		mutateFirstRecord(t, dir, func(record *appDumpRecord) { record.KeyBase64 = "%%%=" })
		if _, _, _, _, _, err := snapshotReader(t, dir, Limits{}, nil).ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "decode key") {
			t.Fatalf("expected strict base64 rejection, got %v", err)
		}
	})
}

func mutateFirstRecord(t *testing.T, dir string, mutate func(*appDumpRecord)) {
	t.Helper()
	raw, err := os.ReadFile(dir + "/app-kv.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	var record appDumpRecord
	if err := json.Unmarshal(raw[:len(raw)-1], &record); err != nil {
		t.Fatal(err)
	}
	mutate(&record)
	line, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/app-kv.jsonl", append(line, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	rewriteSummaryDumpSHA(t, dir)
}

func rewriteSummaryDumpSHA(t *testing.T, dir string) {
	t.Helper()
	raw, err := os.ReadFile(dir + "/app-kv.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	summary, err := os.ReadFile(dir + "/summary.json")
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(summary, &fields); err != nil {
		t.Fatal(err)
	}
	fields["kv_dump_sha256"], _ = json.Marshal(hex.EncodeToString(sum[:]))
	updated, _ := json.Marshal(fields)
	if err := os.WriteFile(dir+"/summary.json", updated, 0600); err != nil {
		t.Fatal(err)
	}
}

func writeSummaryStoreCount(t *testing.T, dir string, count uint64) {
	t.Helper()
	summary, err := os.ReadFile(dir + "/summary.json")
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(summary, &fields); err != nil {
		t.Fatal(err)
	}
	stores := []inspectorStoreInventory{{Name: "s", KVCount: count, LogicalBytes: 2}}
	fields["stores"], _ = json.Marshal(stores)
	updated, _ := json.Marshal(fields)
	if err := os.WriteFile(dir+"/summary.json", updated, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestReadApplicationSnapshotRejectsSubstitutionAndOversize(t *testing.T) {
	dir := t.TempDir()
	dump := makeAppDumpFixture(t, dir, []fixtureKV{{Store: "s", Key: []byte("k"), Value: []byte("v")}}, []inspectorStoreInventory{{Name: "s"}})
	wrong := sha256.Sum256([]byte("substituted"))
	r := snapshotReader(t, dir, Limits{}, map[string]string{"app-kv.jsonl": hex.EncodeToString(wrong[:])})
	if _, _, _, _, _, err := r.ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "differs from local source mapping") {
		t.Fatalf("expected local substitution pin rejection, got %v", err)
	}
	r = snapshotReader(t, dir, Limits{AppKVDump: int64(len(dump) - 1)}, nil)
	if _, _, _, _, _, err := r.ReadApplicationSnapshot("node"); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected bounded dump rejection, got %v", err)
	}
}
