(function attachGatewayState(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.GDC_GATEWAY_STATE = api;
}(typeof globalThis === 'object' ? globalThis : this, function gatewayStateFactory() {
  function activeRuntime(state) {
    if (!state || typeof state !== 'object') return false;
    if (state.escrow_id) {
      return state.phase === 'active' && state.requests_blocked !== true;
    }
    return (Array.isArray(state.devshards) ? state.devshards : []).some(item =>
      item && item.active === true && item.phase === 'active' && item.requests_blocked !== true
    );
  }

  function probeIsFresh(probe, nowMs, maxAgeMs) {
    const checkedAt = Date.parse(probe && probe.checked_at);
    return Number.isFinite(checkedAt) && nowMs - checkedAt >= 0 && nowMs - checkedAt <= maxAgeMs;
  }

  function classify(state, healthyNodes, probe, nowMs = Date.now(), maxAgeMs = 30000) {
    if (healthyNodes === 0) {
      return { state: 'OFFLINE', available: false, message: 'Network reset – no nodes online' };
    }
    const devshards = Array.isArray(state && state.devshards) ? state.devshards : [];
    if (state && state.mode === 'gateway' && Number(state.runtimes) === 0 && devshards.length === 0) {
      return { state: 'PENDING', available: false, message: 'Awaiting governance approval and an active DevShard' };
    }
    if (!activeRuntime(state)) {
      return { state: 'UNAVAILABLE', available: false, message: 'Gateway unavailable – no active DevShard' };
    }
    if (!probeIsFresh(probe, nowMs, maxAgeMs)) {
      return { state: 'UNAVAILABLE', available: false, message: 'Gateway unavailable – inference health check is stale' };
    }
    if (probe.state !== 'READY') {
      return { state: 'UNAVAILABLE', available: false, message: 'Gateway unavailable – inference health check failed' };
    }
    return { state: 'AVAILABLE', available: true, message: 'Gateway is accepting inference traffic' };
  }

  return { activeRuntime, probeIsFresh, classify };
}));
