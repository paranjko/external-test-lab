// @flow strict

declare var module: any;

type HostStateInput = {
  participantKnown?: boolean,
  participantStatus?: mixed,
  validatorKnown?: boolean,
  votingPower?: mixed,
  endpointState?: string,
  endpointDiagnostic?: mixed,
  catchingUp?: boolean,
  blocksBehind?: mixed,
  blockAgeSeconds?: mixed,
  progressing?: ?boolean,
  referenceKnown?: boolean,
  referenceAgrees?: boolean,
};

type HostState = {
  state: "validating" | "active" | "inactive" | "unknown",
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
