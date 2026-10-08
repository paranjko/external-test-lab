// Package cli owns command registration. Domain command registration begins in
// later bounded tasks; this root intentionally performs no environment probes.
package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

const Version = "devel"

func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "gonkactl",
		Short:         "local Gonka deployment control",
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       Version,
	}
	root.AddCommand(&cobra.Command{
		Use:   "version",
		Short: "print the gonkactl version",
		Args:  cobra.NoArgs,
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintln(cmd.OutOrStdout(), Version)
		},
	})
	return root
}
