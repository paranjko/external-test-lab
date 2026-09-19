package legacyv1

import (
	"errors"
	"math/big"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

var ErrInvalidSigningState = errors.New("invalid legacy signing state")
var ErrConflictingBlockID = errors.New("conflicting block ID at equal HRS")

// CompareHRS compares H/R/S exactly, without converting legacy decimal text to
// float64. Equal tuples must not silently merge distinct complete block IDs.
func CompareHRS(a, b model.SigningState) (int, error) {
	ah, err := decimal(a.Height)
	if err != nil {
		return 0, err
	}
	bh, err := decimal(b.Height)
	if err != nil {
		return 0, err
	}
	if c := ah.Cmp(bh); c != 0 {
		return c, nil
	}
	ar, err := decimal(a.Round)
	if err != nil {
		return 0, err
	}
	br, err := decimal(b.Round)
	if err != nil {
		return 0, err
	}
	if c := ar.Cmp(br); c != 0 {
		return c, nil
	}
	if a.Step < b.Step {
		return -1, nil
	}
	if a.Step > b.Step {
		return 1, nil
	}
	if !sameBlockID(a.BlockID, b.BlockID) {
		return 0, ErrConflictingBlockID
	}
	return 0, nil
}

func decimal(value string) (*big.Int, error) {
	if value == "" {
		return nil, ErrInvalidSigningState
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return nil, ErrInvalidSigningState
		}
	}
	n, ok := new(big.Int).SetString(value, 10)
	if !ok {
		return nil, ErrInvalidSigningState
	}
	return n, nil
}

func sameBlockID(a, b *model.BlockID) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Hash == b.Hash && a.PartsTotal == b.PartsTotal && a.PartsHash == b.PartsHash
}
