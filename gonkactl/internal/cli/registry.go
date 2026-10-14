// Package cli owns command registration. Domain command registration begins in
// later bounded tasks; this root intentionally performs no environment probes.
package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// Release metadata is supplied by the build, with useful source-build defaults.
var Version = "devel"
var Commit = "unknown"
var BuildDate = "unknown"

func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "gonkactl",
		Short:         "local Gonka deployment control",
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       Version,
	}
	root.SetVersionTemplate("{{.Version}}\n")
	root.AddCommand(&cobra.Command{
		Use:   "version",
		Short: "print the gonkactl version",
		Args:  cobra.NoArgs,
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "%s\ncommit: %s\nbuilt: %s\n", Version, Commit, BuildDate)
		},
	})
	root.AddCommand(newBootstrapCommand())
	return root
}
