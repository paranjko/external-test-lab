package identity

// ImportMnemonic is intentionally kept at the account-verification boundary:
// mnemonic material is never persisted by this package. Full verification
// delegates derivation to the pinned inferenced CLI through contracts.Runner.
func ImportMnemonic(mnemonic string) bool { return validMnemonicShape(mnemonic) }
