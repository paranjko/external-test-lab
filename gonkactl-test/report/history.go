package report

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type HistoryPoint struct {
	ExecutionID       string `json:"execution_id"`
	ProtocolHistoryID string `json:"protocol_history_id"`
	EvidenceHistoryID string `json:"evidence_history_id"`
	RunID             string `json:"run_id"`
	FinishedAt        string `json:"finished_at"`
}

// PromoteHistory is the sole finalizer for a history scope. The durable
// transaction precedes the atomic history commit; retry recovers a commit for
// which the receipt was interrupted without appending another point.
func PromoteHistory(historyPath, receiptPath, transactionPath string, point HistoryPoint, interruptAfterCommit bool) error {
	if point.ExecutionID == "" || point.ProtocolHistoryID == "" || point.EvidenceHistoryID == "" || point.RunID == "" {
		return fmt.Errorf("history identities are incomplete")
	}
	if point.FinishedAt == "" {
		point.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	if err := os.MkdirAll(filepath.Dir(historyPath), 0755); err != nil {
		return err
	}
	lock, err := os.OpenFile(historyPath+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if _, err := os.Stat(receiptPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	old, err := os.ReadFile(historyPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	line, err := json.Marshal(point)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	if bytes.Contains(old, []byte(`"execution_id":"`+point.ExecutionID+`"`)) {
		return atomicWrite(receiptPath, []byte("recovered-after-history-commit\n"), 0600)
	}
	tx, _ := json.MarshalIndent(map[string]any{"state": "prepared", "point": point}, "", "  ")
	if err := atomicWrite(transactionPath, append(tx, '\n'), 0600); err != nil {
		return err
	}
	if err := atomicWrite(historyPath, append(old, line...), 0600); err != nil {
		return err
	}
	if interruptAfterCommit {
		return fmt.Errorf("injected interruption after history commit")
	}
	if err := atomicWrite(receiptPath, []byte("committed\n"), 0600); err != nil {
		return err
	}
	return atomicWrite(transactionPath, []byte("{\"state\":\"committed\"}\n"), 0600)
}
