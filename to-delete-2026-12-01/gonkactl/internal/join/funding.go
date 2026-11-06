package join

// FaucetOutcome classifies only the frozen DevNet response boundary: a 202
// carries a transaction hash and a 409 means read balance before any retry.
func FaucetOutcome(status int, txHash string) string {
	if status == 202 && len(txHash) == 64 {
		return "submitted"
	}
	if status == 409 {
		return "readback_required"
	}
	return "refused"
}
