package operation

import (
	"context"
	"errors"
)

var ErrIntentMissing = errors.New("durable transaction intent is required")
var ErrOutcomeUnknown = errors.New("transaction outcome remains unknown after readback")

// ReconcileWrite never retries an ambiguous write. A caller must persist its
// prepared intent first; a timeout/error is followed by the authoritative
// readback and only a proved absent effect may be presented for a later retry.
func ReconcileWrite(ctx context.Context, intentRecorded bool, readback func(context.Context) (bool, error), write func(context.Context) error) (string, error) {
	if !intentRecorded {
		return "", ErrIntentMissing
	}
	found, err := readback(ctx)
	if err != nil {
		return "", err
	}
	if found {
		return "effect_already_present", nil
	}
	if err := write(ctx); err == nil {
		return "broadcast_accepted", nil
	}
	found, readErr := readback(ctx)
	if readErr != nil {
		return "", readErr
	}
	if found {
		return "effect_found_after_timeout", nil
	}
	return "", ErrOutcomeUnknown
}
