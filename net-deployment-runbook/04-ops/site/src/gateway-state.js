// @flow strict

declare var module: any;

type DevShardRuntime = {
  id?: string | number,
  escrow_id?: string | number,
  active?: boolean,
  phase?: string,
  requests_blocked?: boolean,
};

type GatewayCapacity = {
  total_weight?: number | string,
  scale_factor?: number | string,
};

type GatewayState = {
  mode?: string,
  runtimes?: number,
  escrow_id?: string | number,
  phase?: string,
  requests_blocked?: boolean,
  capacity?: GatewayCapacity,
  devshards?: Array<DevShardRuntime>,
};

type GatewayRecovery = {
  escrow_id?: string | number,
  started_at?: string,
  next_check_seconds?: number | string,
};

type GatewayProbe = {
  state?: string,
  readiness?: string,
  reason?: string,
  checked_at?: string,
  completion_finished_ms?: number,
  admission?: string,
  admission_id?: string,
  safe_generation?: string,
  arrival_height?: number,
  permit_height?: number,
  dispatch_height?: number,
  response_height?: number,
  recovery?: GatewayRecovery,
};

type GatewayAdmission = {
  available?: boolean,
  reason?: string,
};

type GatewayAvailability = {
  state: string,
  available: boolean,
  message: string,
  startedAt?: string,
};

type GatewayStateApi = {
  activeRuntime: (state: ?GatewayState) => boolean,
  probeIsFresh: (
    probe: ?GatewayProbe,
    nowMs: number,
    maxAgeMs: number,
  ) => boolean,
  recoveryMessage: (probe: ?GatewayProbe) => string,
  classify: (
    state: ?GatewayState,
    healthyNodes: number,
    probe: ?GatewayProbe,
    nowMs?: number,
    maxAgeMs?: number,
    admission?: ?GatewayAdmission,
  ) => GatewayAvailability,
};
(function attachGatewayState(root: any, factory: () => GatewayStateApi) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_GATEWAY_STATE = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function gatewayStateFactory(): GatewayStateApi {
    function hasCurrentCapacity(state: GatewayState): boolean {
      const capacity = state && state.capacity;
      if (!capacity || typeof capacity !== "object") return true;
      const totalWeight = Number(capacity.total_weight);
      const scaleFactor = Number(capacity.scale_factor);
      if (Number.isFinite(totalWeight) && totalWeight <= 0) return false;
      if (Number.isFinite(scaleFactor) && scaleFactor <= 0) return false;
      return true;
    }

    function activeRuntime(state: ?GatewayState): boolean {
      if (!state || typeof state !== "object") return false;
      if (!hasCurrentCapacity(state)) return false;
      if (state.escrow_id) {
        return (
          typeof state.phase === "string" &&
          typeof state.requests_blocked === "boolean" &&
          state.phase === "active" &&
          state.requests_blocked === false
        );
      }
      return (Array.isArray(state.devshards) ? state.devshards : []).some(
        (item) =>
          item &&
          typeof item.active === "boolean" &&
          typeof item.phase === "string" &&
          typeof item.requests_blocked === "boolean" &&
          item.active === true &&
          item.phase === "active" &&
          item.requests_blocked === false,
      );
    }

    function probeIsFresh(
      probe: ?GatewayProbe,
      nowMs: number,
      maxAgeMs: number,
    ): boolean {
      const checkedAt = Date.parse(probe?.checked_at || "");
      return (
        Number.isFinite(checkedAt) &&
        nowMs - checkedAt >= 0 &&
        nowMs - checkedAt <= maxAgeMs
      );
    }

    function hasTrafficReceipt(probe: GatewayProbe, nowMs: number): boolean {
      const completionFinishedMs = Number(probe?.completion_finished_ms);
      const arrivalHeight = Number(probe?.arrival_height);
      const permitHeight = Number(probe?.permit_height);
      const dispatchHeight = Number(probe?.dispatch_height);
      const responseHeight = Number(probe?.response_height);
      return (
        probe?.state === "READY" &&
        probe?.readiness === "TRAFFIC_READY" &&
        probe?.reason === "completion_succeeded" &&
        probe?.admission === "dispatched_once" &&
        typeof probe?.admission_id === "string" &&
        /^[a-f0-9]{32}$/.test(probe.admission_id) &&
        typeof probe?.safe_generation === "string" &&
        /^sha256:[a-f0-9]{64}$/.test(probe.safe_generation) &&
        Number.isFinite(completionFinishedMs) &&
        completionFinishedMs > 0 &&
        completionFinishedMs <= nowMs &&
        [arrivalHeight, permitHeight, dispatchHeight, responseHeight].every(
          (height) => Number.isInteger(height) && height > 0,
        ) &&
        arrivalHeight <= permitHeight &&
        permitHeight <= dispatchHeight &&
        dispatchHeight <= responseHeight
      );
    }

    function recoveryMessage(probe: ?GatewayProbe): string {
      const recovery =
        probe && probe.recovery && typeof probe.recovery === "object"
          ? probe.recovery
          : {};
      const escrow = recovery.escrow_id
        ? `Escrow #${recovery.escrow_id}`
        : "Gateway";
      const stage = String(
        (probe && probe.reason) || "replacement_escrow_recovering",
      );
      const messages: { [string]: string } = {
        replacement_escrow_creating:
          "No valid runtime remains – creating a replacement escrow",
        waiting_for_chain_confirmation: `${escrow} was submitted – waiting for chain confirmation`,
        waiting_for_routable_runtime: `${escrow} is confirmed – activating its gateway runtime`,
        waiting_for_versiond_session: `${escrow} is active – waiting for its versiond inference session`,
        waiting_for_poc_preserved_runtime:
          "PoC is active – waiting for a chain-permitted inference runtime",
        gateway_admin_unavailable:
          "The gateway controller is not reachable – retrying its admin endpoint",
        chain_escrow_query_unavailable:
          "Chain escrow state is temporarily unavailable – keeping existing runtimes unchanged",
      };
      const detail =
        messages[stage] || `Recovery stage: ${stage.replaceAll("_", " ")}`;
      const retry = Number(recovery.next_check_seconds);
      return retry > 0
        ? `${detail} – next check within ${retry} seconds`
        : detail;
    }

    function classify(
      state: ?GatewayState,
      healthyNodes: number,
      probe: ?GatewayProbe,
      nowMs: number = Date.now(),
      maxAgeMs: number = 30000,
      admission: ?GatewayAdmission = null,
    ): GatewayAvailability {
      const currentProbe: GatewayProbe = probe || {};
      const currentState: GatewayState = state || {};
      if (healthyNodes === 0) {
        return {
          state: "OFFLINE",
          available: false,
          message: "Network reset – no nodes online",
        };
      }
      if (admission && admission.available === false) {
        const reason =
          typeof admission.reason === "string" && admission.reason
            ? admission.reason.replaceAll("_", " ")
            : "admission state is unavailable";
        return {
          state: "UNAVAILABLE",
          available: false,
          message: `Gateway unavailable – ${reason}`,
        };
      }
      if (
        probeIsFresh(currentProbe, nowMs, maxAgeMs) &&
        currentProbe.state === "RECOVERING"
      ) {
        return {
          state: "RECOVERING",
          available: false,
          message: recoveryMessage(currentProbe),
          startedAt:
            (currentProbe.recovery && currentProbe.recovery.started_at) || "",
        };
      }
      const readiness =
        typeof currentProbe.readiness === "string"
          ? currentProbe.readiness
          : "";
      if (
        probeIsFresh(currentProbe, nowMs, maxAgeMs) &&
        ["CONTROL_READY", "ROUTING_READY", "SATURATED"].includes(
          readiness,
        )
      ) {
        const messages: { [string]: string } = {
          CONTROL_READY:
            "Gateway control plane is ready – inference route is not ready",
          ROUTING_READY:
            "Gateway route is ready – traffic is paused by the reserve guard",
          SATURATED:
            "Gateway is saturated – retry after capacity is available",
        };
        return {
          state: readiness,
          available: false,
          message: messages[readiness],
        };
      }
      if (
        probeIsFresh(currentProbe, nowMs, maxAgeMs) &&
        currentProbe.state !== "READY"
      ) {
        const reason = String(
          currentProbe.reason || "inference health check failed",
        ).replaceAll("_", " ");
        return {
          state: "UNAVAILABLE",
          available: false,
          message: `Gateway unavailable – ${reason}`,
        };
      }
      if (probeIsFresh(currentProbe, nowMs, maxAgeMs) && readiness !== "TRAFFIC_READY") {
        return {
          state: "UNAVAILABLE",
          available: false,
          message: "Gateway unavailable – traffic readiness is unknown",
        };
      }
      const devshards = Array.isArray(currentState.devshards)
        ? currentState.devshards
        : [];
      if (
        currentState.mode === "gateway" &&
        Number(currentState.runtimes) === 0 &&
        devshards.length === 0
      ) {
        return {
          state: "PENDING",
          available: false,
          message: "Awaiting governance approval and an active DevShard",
        };
      }
      if (!activeRuntime(currentState)) {
        return {
          state: "UNAVAILABLE",
          available: false,
          message: hasCurrentCapacity(currentState)
            ? "Gateway unavailable – no active DevShard"
            : "Gateway unavailable – no current eligible inference capacity",
        };
      }
      if (!probeIsFresh(currentProbe, nowMs, maxAgeMs)) {
        return {
          state: "UNAVAILABLE",
          available: false,
          message: "Gateway unavailable – inference health check is stale",
        };
      }
      if (currentProbe.state !== "READY") {
        return {
          state: "UNAVAILABLE",
          available: false,
          message: "Gateway unavailable – inference health check failed",
        };
      }
      if (!hasTrafficReceipt(currentProbe, nowMs)) {
        return {
          state: "UNAVAILABLE",
          available: false,
          message: "Gateway unavailable – traffic receipt is incomplete",
        };
      }
      return {
        state:
          readiness === "TRAFFIC_READY" ? "TRAFFIC_READY" : "AVAILABLE",
        available: true,
        message: "Gateway is accepting inference traffic",
      };
    }

    return { activeRuntime, probeIsFresh, recoveryMessage, classify };
  },
);
