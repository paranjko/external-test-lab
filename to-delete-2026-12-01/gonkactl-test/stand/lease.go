package stand

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var ErrLeaseHeld = errors.New("fixture lease is already held")

type Lease struct {
	EnvironmentID string `json:"environment_id"`
	InstanceID    string `json:"instance_id"`
	Token         string `json:"token"`
	CreatedAt     string `json:"created_at"`
	Path          string `json:"-"`
}

func AcquireLease(dataRoot, environmentID, instanceID string) (Lease, error) {
	if err := safeIdentifier(environmentID); err != nil {
		return Lease{}, err
	}
	if err := safeIdentifier(instanceID); err != nil {
		return Lease{}, err
	}
	root, err := filepath.Abs(dataRoot)
	if err != nil {
		return Lease{}, err
	}
	if strings.HasPrefix(root, os.TempDir()+string(filepath.Separator)) || root == os.TempDir() {
		return Lease{}, fmt.Errorf("system temporary directory is forbidden: %s", root)
	}
	directory := filepath.Join(root, "leases", environmentID)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return Lease{}, err
	}
	path := filepath.Join(directory, instanceID+".json")
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return Lease{}, err
	}
	lease := Lease{EnvironmentID: environmentID, InstanceID: instanceID, Token: hex.EncodeToString(token), CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Path: path}
	encoded, err := json.Marshal(lease)
	if err != nil {
		return Lease{}, err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return Lease{}, fmt.Errorf("%w: %s", ErrLeaseHeld, path)
	}
	if err != nil {
		return Lease{}, err
	}
	_, writeErr := file.Write(append(encoded, '\n'))
	closeErr := file.Close()
	if writeErr != nil {
		return Lease{}, writeErr
	}
	if closeErr != nil {
		return Lease{}, closeErr
	}
	return lease, nil
}

func (l Lease) Release() error {
	contents, err := os.ReadFile(l.Path)
	if err != nil {
		return err
	}
	var stored Lease
	if err := json.Unmarshal(contents, &stored); err != nil {
		return fmt.Errorf("read lease: %w", err)
	}
	if stored.Token != l.Token || stored.EnvironmentID != l.EnvironmentID || stored.InstanceID != l.InstanceID {
		return errors.New("lease token does not own this resource")
	}
	return os.Remove(l.Path)
}

func safeIdentifier(value string) error {
	if value == "" || value != filepath.Base(value) || strings.Contains(value, "..") {
		return fmt.Errorf("unsafe identifier %q", value)
	}
	return nil
}
