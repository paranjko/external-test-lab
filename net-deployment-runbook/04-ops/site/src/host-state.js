// @flow strict

declare var module: any;

type HostStateInput = {
  networkObserved?: boolean,
  networkActive?: boolean,
  participantKnown?: boolean,
  participantStatus?: mixed,
  validatorKnown?: boolean,
  observationComplete?: boolean,
  votingPower?: mixed,
  endpointState?: string,
  endpointDiagnostic?: mixed,
  chainDiagnostic?: mixed,
  catchingUp?: boolean,
  blocksBehind?: mixed,
  blockAgeSeconds?: mixed,
  progressing?: ?boolean,
  referenceKnown?: boolean,
  referenceAgrees?: boolean,
};

type HostState = {
  state: "validating" | "active" | "degraded" | "inactive" | "unknown" | "unavailable",
  stateLabel: string,
  reason: string,
  primaryLabel: string,
  primaryClass: string,
  votingPower: string,
  endpointLabel: string,
  syncLabel: string,
  validatorEffective: boolean,
};

type HostStateApi = {
  isActiveParticipant: (status: mixed) => boolean,
  classify: (input: HostStateInput) => HostState,
  endpointDiagnostic: (error: mixed) => string,
};

(function attachHostState(root: any, factory: () => HostStateApi) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_HOST_STATE = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function hostStateFactory(): HostStateApi {
    function isActiveParticipant(status: mixed): boolean {
      const normalized = String(status || "").trim().toUpperCase();
      return (
        normalized === "ACTIVE" ||
        normalized === "PARTICIPANT_STATUS_ACTIVE" ||
        normalized === "1"
      );
    }

    function normalizedVotingPower(value: mixed): ?string {
      const text = String(value === null || value === undefined ? "" : value).trim();
      if (!/^\d+$/.test(text)) return null;
      try {
        const power = BigInt(text);
        return power >= 0n ? String(power) : null;
      } catch {
        return null;
      }
    }

    function endpointDiagnostic(error: mixed): string {
      const message =
        error instanceof Error ? error.message.trim() : String(error || "").trim();
      const httpStatus = message.match(/\b([45]\d\d)\b/);
      if (httpStatus) return `HTTP ${httpStatus[1]}`;
      if (/abort|timeout/i.test(message)) return "Timed out";
      if (/failed to fetch|network|dns|name resolution/i.test(message))
        return "Network error";
      return "Check endpoint";
    }

    function classify(input: HostStateInput): HostState {
      if (input.networkObserved === true) {
        const endpointState = input.endpointState || "unknown";
        const diagnostic = String(input.endpointDiagnostic || "Network peer unavailable");
        const lag = input.blocksBehind == null ? NaN : Number(input.blocksBehind);
        const blockAge = input.blockAgeSeconds == null ? NaN : Number(input.blockAgeSeconds);
        const power = input.validatorKnown === true ? normalizedVotingPower(input.votingPower) : null;
        const syncLabel =
          endpointState === "unavailable"
              ? "Unavailable"
              : endpointState !== "reachable"
                ? "Pending observation"
              : input.catchingUp === true || (input.referenceKnown === true && Number.isFinite(lag) && lag > 5)
                ? Number.isFinite(lag) && lag > 0
                  ? `Lagging – ${Math.floor(lag).toLocaleString()} blocks`
                  : "Lagging"
                : Number.isFinite(blockAge) && (blockAge > 90 || input.progressing === false)
                  ? "Stale"
                  : endpointState !== "reachable" || input.catchingUp !== false || input.referenceKnown !== true || input.referenceAgrees !== true || !Number.isFinite(lag) || !Number.isFinite(blockAge)
                    ? "Pending observation"
                    : "Synced";
        // Membership and endpoint health are different facts. The primary
        // badge describes the verified current set; sync remains a detail.
        const validating = power != null && BigInt(power) > 0n;
        if (endpointState === "unavailable") {
          return {
            state: "unavailable",
            stateLabel: "Unavailable",
            reason: "Public chain endpoint unavailable; P2P visibility is independent",
            primaryLabel: "Unavailable",
            primaryClass: "status unavailable",
            votingPower: "Unavailable",
            endpointLabel: `Unreachable – ${diagnostic}`,
            syncLabel,
            validatorEffective: false,
          };
        }
        if (endpointState !== "reachable") {
          const failed = input.observationComplete === true;
          return {
            state: failed ? "unavailable" : "unknown",
            stateLabel: failed ? "Unavailable" : "Checking",
            reason: String(input.chainDiagnostic || (endpointState === "reachable"
              ? "Current validator membership is not verified"
              : "Checking public chain endpoint")),
            primaryLabel: failed ? "Unavailable" : "Checking",
            primaryClass: failed ? "status unavailable" : "status unknown",
            votingPower: "Unavailable",
            endpointLabel: endpointState === "reachable" ? "Reachable" : failed ? "Unavailable" : "Checking",
            syncLabel,
            validatorEffective: false,
          };
        }
        return {
            state: validating ? "validating" : "active",
            stateLabel: validating ? "Validating" : "Active",
            reason: input.chainDiagnostic
              ? String(input.chainDiagnostic)
              : validating
                ? "Member of the current validator set"
                : power === null
                  ? "Public chain endpoint reachable; checking validator membership"
                  : "Public chain endpoint reachable; not in the current validator set",
            primaryLabel: validating ? "Validating" : "Active",
            primaryClass: validating ? "status validating" : "status active",
          votingPower: power == null ? "Unavailable" : power,
          endpointLabel: "Reachable",
          syncLabel,
            // Gateway capacity still needs a synchronized endpoint. Do not
            // turn a presentation change into an inference-readiness claim.
            validatorEffective: validating && syncLabel === "Synced",
        };
      }
      const participantKnown = input.participantKnown === true;
      const validatorKnown = input.validatorKnown === true;
      const power = normalizedVotingPower(input.votingPower);
      const endpointState = input.endpointState || "unknown";
      const diagnostic = String(input.endpointDiagnostic || "Check endpoint");
      const endpointLabel =
        endpointState === "reachable"
          ? "Reachable"
          : endpointState === "unavailable"
            ? `Unavailable – ${diagnostic}`
            : "Unknown";
      const lag = Number(input.blocksBehind);
      const blockAge = Number(input.blockAgeSeconds);
      const referenceKnown = input.referenceKnown !== false;
      const referenceAgrees = input.referenceAgrees !== false;
      const syncLabel =
        endpointState === "unavailable"
          ? "Unavailable"
          : endpointState !== "reachable"
            ? "Unknown"
            : !referenceKnown || !referenceAgrees
              ? "Unknown"
            : input.catchingUp === true
              ? Number.isFinite(lag) && lag > 0
                ? `Lagging – ${Math.floor(lag).toLocaleString()} blocks`
                : "Lagging"
              : !Number.isFinite(lag) || !Number.isFinite(blockAge)
                ? "Unknown"
                : lag > 5
                  ? `Lagging – ${Math.floor(lag).toLocaleString()} blocks`
                  : blockAge > 90 || input.progressing === false
                    ? "Stale"
                    : "Synced";

      if (!participantKnown) {
        return {
          state: "unknown",
          stateLabel: "Unknown",
          reason: "Participant data unavailable",
          primaryLabel: "Unknown",
          primaryClass: "status unknown",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (!isActiveParticipant(input.participantStatus)) {
        return {
          state: "inactive",
          stateLabel: "Inactive",
          reason: "Participant inactive",
          primaryLabel: "Inactive",
          primaryClass: "status inactive",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      // The participant registry says whether a Host belongs to the network,
      // but it does not prove that the browser has completed the endpoint
      // observation.  Do not briefly paint a new card as Active and then
      // replace it with Inactive when that observation arrives.
      if (endpointState !== "reachable" && endpointState !== "unavailable") {
        return {
          state: "unknown",
          stateLabel: "Unknown",
          reason: "Endpoint status is being checked",
          primaryLabel: "Unknown",
          primaryClass: "status unknown",
          votingPower: power === null ? "Unavailable" : String(power),
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      // A Host that cannot serve its public chain endpoint is inactive for
      // operators, even if its last chain registry record still says ACTIVE.
      // This keeps the card and map from presenting a dead endpoint as an
      // available participant during the interval before chain cleanup.
      if (endpointState === "unavailable") {
        return {
          state: "inactive",
          stateLabel: "Inactive",
          reason: "Public endpoint unavailable",
          primaryLabel: "Inactive",
          primaryClass: "status inactive",
          votingPower: power === null ? "Unavailable" : String(power),
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (!validatorKnown) {
        return {
          state: "unknown",
          stateLabel: "Unknown",
          reason: "Validator data unavailable",
          primaryLabel: "Unknown",
          primaryClass: "status unknown",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (power === null) {
        return {
          state: "unknown",
          stateLabel: "Unknown",
          reason: "Validator voting power unavailable",
          primaryLabel: "Unknown",
          primaryClass: "status unknown",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      const confirmedPower = String(power);
      if (BigInt(confirmedPower) > 0n) {
        const validating = endpointState === "reachable" && syncLabel === "Synced";
        return {
          state: validating ? "validating" : "active",
          stateLabel: validating ? "Validating" : "Active",
          reason: validating
            ? "Effective and synchronized validator"
            : "Active participant, currently not validating",
          primaryLabel: validating ? "Validating" : "Active",
          primaryClass: validating ? "status validating" : "status active",
          votingPower: confirmedPower,
          endpointLabel,
          syncLabel,
          validatorEffective: true,
        };
      }
      return {
        // An active participant with zero voting power is still available to
        // the network; it is simply not validating in the current set.
        state: "active",
        stateLabel: "Active",
        reason: "Not in validator set",
        primaryLabel: "Active",
        primaryClass: "status active",
        votingPower: "0",
        endpointLabel,
        syncLabel,
        validatorEffective: false,
      };
    }

    return { isActiveParticipant, classify, endpointDiagnostic };
  },
);
