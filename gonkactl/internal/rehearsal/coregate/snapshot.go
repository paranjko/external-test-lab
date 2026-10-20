package coregate

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type inspectorStoreInventory struct {
	Name         string `json:"name"`
	KVCount      uint64 `json:"kv_count"`
	LogicalBytes uint64 `json:"logical_bytes"`
	RootHash     string `json:"root_hash,omitempty"`
}

type appDumpRecord struct {
	Store       string `json:"store"`
	KeyBase64   string `json:"key_base64"`
	ValueBase64 string `json:"value_base64"`
	KeySHA256   string `json:"key_sha256"`
	ValueSHA256 string `json:"value_sha256"`
}

// ReadApplicationSnapshot converts the saved gnklab-state-inspect summary.json
// and app-kv.jsonl into a complete application snapshot. The summary's dump
// digest/counts are checked against the exact saved dump bytes, and each
// decoded key/value is checked against its record digest. Returned source
// digests describe local file bytes; they are not an authenticated run receipt.
func (r *FileEvidenceReader) ReadApplicationSnapshot(node string) (contract.Snapshot, []byte, []byte, SourceDigest, SourceDigest, error) {
	var empty contract.Snapshot
	summaryRaw, summaryDigest, err := r.read(node, "summary.json", r.limits.InspectorJSON)
	if err != nil {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, err
	}
	var root map[string]json.RawMessage
	if err := contract.DecodeStrict(summaryRaw, &root); err != nil {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("decode application dump summary: %w", err)
	}
	if root == nil {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application dump summary must be an object")
	}
	var dumpFile, dumpSHA string
	var recordCount, totalLogicalBytes uint64
	var inventory []inspectorStoreInventory
	for _, field := range []struct {
		name string
		dst  any
	}{{"kv_dump_file", &dumpFile}, {"kv_dump_sha256", &dumpSHA}, {"kv_dump_record_count", &recordCount}, {"kv_dump_logical_bytes", &totalLogicalBytes}, {"stores", &inventory}} {
		raw, ok := root[field.name]
		if !ok {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application dump summary missing %s", field.name)
		}
		if err := contract.DecodeStrict(raw, field.dst); err != nil {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("decode application dump summary %s: %w", field.name, err)
		}
	}
	if dumpFile != "app-kv.jsonl" || !validDigest(dumpSHA) {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application dump summary has unsupported file or digest")
	}
	if inventory == nil {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application store inventory is missing")
	}

	dumpRaw, dumpDigest, err := r.read(node, "app-kv.jsonl", r.limits.AppKVDump)
	if err != nil {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, err
	}
	if dumpDigest.SHA256 != dumpSHA {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application KV dump digest differs from summary")
	}

	snapshot := contract.Snapshot{Stores: make([]contract.LogicalStore, 0, len(inventory))}
	storeIndex := make(map[string]int, len(inventory))
	expectedCount := make(map[string]uint64, len(inventory))
	expectedLogical := make(map[string]uint64, len(inventory))
	for _, store := range inventory {
		if strings.TrimSpace(store.Name) == "" {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application store inventory contains an empty name")
		}
		if _, duplicate := storeIndex[store.Name]; duplicate {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("duplicate application store %q", store.Name)
		}
		storeIndex[store.Name] = len(snapshot.Stores)
		expectedCount[store.Name] = store.KVCount
		expectedLogical[store.Name] = store.LogicalBytes
		snapshot.Stores = append(snapshot.Stores, contract.LogicalStore{Name: store.Name, Entries: make([]contract.Entry, 0)})
	}

	seenKeys := make(map[string]map[string]struct{}, len(inventory))
	var records, logicalBytes uint64
	if len(dumpRaw) != 0 {
		if dumpRaw[len(dumpRaw)-1] != '\n' {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application KV dump has an unterminated final record")
		}
		lines := bytes.Split(dumpRaw[:len(dumpRaw)-1], []byte{'\n'})
		for lineNo, line := range lines {
			if len(line) == 0 {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application KV dump contains an empty record at line %d", lineNo+1)
			}
			var record appDumpRecord
			if err := contract.DecodeStrict(line, &record); err != nil {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("decode application KV record %d: %w", lineNo+1, err)
			}
			idx, ok := storeIndex[record.Store]
			if !ok {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("KV record references store absent from inventory: %q", record.Store)
			}
			key, err := decodeCanonicalBase64(record.KeyBase64)
			if err != nil {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("decode key at record %d: %w", lineNo+1, err)
			}
			value, err := decodeCanonicalBase64(record.ValueBase64)
			if err != nil {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("decode value at record %d: %w", lineNo+1, err)
			}
			if !matchesBytesDigest(record.KeySHA256, key) || !matchesBytesDigest(record.ValueSHA256, value) {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("key/value digest mismatch at record %d", lineNo+1)
			}
			if seenKeys[record.Store] == nil {
				seenKeys[record.Store] = make(map[string]struct{})
			}
			if _, duplicate := seenKeys[record.Store][string(key)]; duplicate {
				return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("duplicate key in store %q", record.Store)
			}
			seenKeys[record.Store][string(key)] = struct{}{}
			snapshot.Stores[idx].Entries = append(snapshot.Stores[idx].Entries, contract.Entry{Key: key, Value: value})
			records++
			logicalBytes += uint64(len(key) + len(value))
		}
	}
	if records != recordCount || records == 0 && len(dumpRaw) != 0 || logicalBytes != totalLogicalBytes {
		return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application KV dump record/logical-byte totals differ from summary")
	}
	for name := range storeIndex {
		idx := storeIndex[name]
		entries := snapshot.Stores[idx].Entries
		if uint64(len(entries)) != expectedCount[name] {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application KV count for store %q differs from inventory", name)
		}
		var storeBytes uint64
		for _, entry := range entries {
			storeBytes += uint64(len(entry.Key) + len(entry.Value))
		}
		if storeBytes != expectedLogical[name] {
			return empty, nil, nil, SourceDigest{}, SourceDigest{}, fmt.Errorf("application logical bytes for store %q differ from inventory", name)
		}
	}
	return snapshot, summaryRaw, dumpRaw, summaryDigest, dumpDigest, nil
}

func decodeCanonicalBase64(encoded string) ([]byte, error) {
	b, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	if base64.StdEncoding.EncodeToString(b) != encoded {
		return nil, fmt.Errorf("non-canonical standard base64")
	}
	return b, nil
}

func matchesBytesDigest(encoded string, raw []byte) bool {
	if !validDigest(encoded) {
		return false
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]) == encoded
}
