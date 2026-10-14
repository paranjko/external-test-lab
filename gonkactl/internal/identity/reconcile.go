package identity

// ReconcileStart resolves a crash after start intent monotonically. A possible
// prior start never authorizes a retired or otherwise changed guard, while an
// existing durable authorization remains restartable without a live RPC call.
func ReconcileStart(guard Guard, observedSigner string) (Guard, error) {
	if err := guard.AllowsStart(); err != nil {
		return Guard{}, err
	}
	if observedSigner == "retired" || observedSigner == "active_conflict" {
		return Guard{}, ErrSignerForbidden
	}
	if observedSigner == "active" {
		guard.State = "ACTIVE"
	}
	return guard, nil
}
