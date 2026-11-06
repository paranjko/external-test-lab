//go:build windows

package cli

import (
	"errors"
	"time"

	"github.com/spf13/cobra"
)

// RehearsalDependencies preserves the root command registration API on
// Windows. Recovery operations are intentionally unavailable on that target.
type RehearsalDependencies struct {
	Clock func() time.Time
}

func newRehearsalCommand(_ RehearsalDependencies) *cobra.Command {
	return &cobra.Command{
		Use:           "recover <scenario> [phase]",
		Short:         "recovery rehearsal operations are unavailable on Windows",
		Args:          cobra.RangeArgs(1, 2),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(*cobra.Command, []string) error {
			return errors.New("recovery rehearsal operations are unavailable on Windows; use a supported Linux or Darwin build")
		},
	}
}
