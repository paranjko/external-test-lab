package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const guardKey = "signer/guard.json"
const guardSchema = "runtime.schema.json#/$defs/guard"

var ErrSignerForbidden = errors.New("signer guard forbids start")

// Guard is the durable subset needed before every managed signer start. The
// complete document is schema-validated before this subset is trusted.
type Guard struct {
	State         string `json:"state"`
	Mode          string `json:"mode"`
	InstanceID    string `json:"instance_id"`
	SignerMayBeOn bool   `json:"signer_may_be_on"`
	Authorization any    `json:"authorization"`
}

func (g Guard) AllowsStart() error {
	if g.State == "RETIRING" || g.State == "RETIRED" {
		return fmt.Errorf("%w: retired lifecycle state", ErrSignerForbidden)
	}
	if g.State != "ACTIVATION_AUTHORIZED" && g.State != "ACTIVE" {
		return fmt.Errorf("%w: state %q is not authorized", ErrSignerForbidden, g.State)
	}
	if !g.SignerMayBeOn || g.Authorization == nil || g.InstanceID == "" {
		return fmt.Errorf("%w: durable start intent or authorization missing", ErrSignerForbidden)
	}
	return nil
}

// ReadGuard validates the exact current file on every start. Reading through
// Store preserves its no-symlink and command-owned-path guarantees.
func ReadGuard(ctx context.Context, store contracts.Store) (Guard, string, error) {
	if store == nil {
		return Guard{}, "", errors.New("signer guard store is unavailable")
	}
	doc, err := store.Read(ctx, guardKey)
	if err != nil {
		return Guard{}, "", err
	}
	var guard Guard
	if err := json.Unmarshal(doc.Bytes, &guard); err != nil {
		return Guard{}, "", fmt.Errorf("decode signer guard: %w", err)
	}
	return guard, doc.SHA256, nil
}

func writeGuard(ctx context.Context, deps contracts.Dependencies, expected *string, raw json.RawMessage) error {
	if deps.Store == nil || deps.Validator == nil {
		return errors.New("signer guard persistence requires store and validator")
	}
	if err := deps.Validator.Validate(guardSchema, raw); err != nil {
		return fmt.Errorf("invalid signer guard: %w", err)
	}
	return deps.Store.CAS(ctx, guardKey, expected, contracts.Document{SchemaRef: guardSchema, Bytes: raw})
}
