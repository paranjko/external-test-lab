package join

// WarmGrantArgs is the exact immutable argument suffix used by the pinned
// inferenced adapter; password material is stdin-only and absent here.
func WarmGrantArgs() []string {
	return []string{"tx", "inference", "grant-ml-ops-permissions", "--keyring-backend", "file", "--gas", "auto", "--gas-adjustment", "1.5", "--gas-prices", "0ngonka", "--broadcast-mode", "sync", "--output", "json", "--yes"}
}
