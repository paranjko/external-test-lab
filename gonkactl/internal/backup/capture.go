package backup

import (
	"errors"
	"sort"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

var ErrRecoveryInput = errors.New("recovery inputs are incomplete")

// Capture keeps retained recovery bytes separate from their eventual archive.
// Callers must provide the complete legacy tree; this package never invents a
// mnemonic, signer state, or identity.
func Capture(members []model.Member) ([]model.Member, error) {
	if len(members) == 0 {
		return nil, ErrRecoveryInput
	}
	copy := append([]model.Member(nil), members...)
	sort.Slice(copy, func(i, j int) bool { return copy[i].Path < copy[j].Path })
	seen := map[string]bool{}
	for _, member := range copy {
		if member.Path == "" || seen[member.Path] {
			return nil, ErrRecoveryInput
		}
		seen[member.Path] = true
	}
	return copy, nil
}
