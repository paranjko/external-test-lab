// Generated from src/host-state.js - edit the Flow source and run make site-js

(function attachHostState(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_HOST_STATE = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function hostStateFactory() {
    function isActiveParticipant(status) {
      const normalized = String(status || "")
        .trim()
        .toUpperCase();
      return (
        normalized === "ACTIVE" ||
        normalized === "PARTICIPANT_STATUS_ACTIVE" ||
        normalized === "1"
      );
    }

    function normalizedVotingPower(value) {
      const text = String(
        value === null || value === undefined ? "" : value,
      ).trim();
      if (!/^\d+$/.test(text)) return null;
      try {
        const power = BigInt(text);
        return power >= 0n ? String(power) : null;
      } catch {
        return null;
      }
    }

    function endpointDiagnostic(error) {
      const message =
        error instanceof Error
          ? error.message.trim()
          : String(error || "").trim();
      const httpStatus = message.match(/\b([45]\d\d)\b/);
      if (httpStatus) return `HTTP ${httpStatus[1]}`;
      if (/abort|timeout/i.test(message)) return "Timed out";
      if (/failed to fetch|network|dns|name resolution/i.test(message))
        return "Network error";
      return "Check endpoint";
    }

    function classify(input) {
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
          primaryLabel: "Participant data unavailable",
          primaryClass: "status bad",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (!isActiveParticipant(input.participantStatus)) {
        return {
          primaryLabel: "Participant inactive",
          primaryClass: "status bad",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (!validatorKnown) {
        return {
          primaryLabel: "Validator data unavailable",
          primaryClass: "status bad",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      if (power === null) {
        return {
          primaryLabel: "Validator data unavailable",
          primaryClass: "status bad",
          votingPower: "Unavailable",
          endpointLabel,
          syncLabel,
          validatorEffective: false,
        };
      }
      const confirmedPower = String(power);
      if (BigInt(confirmedPower) > 0n) {
        return {
          primaryLabel: "Effective validator",
          primaryClass: "status ok",
          votingPower: confirmedPower,
          endpointLabel,
          syncLabel,
          validatorEffective: true,
        };
      }
      return {
        primaryLabel: "Not in validator set",
        primaryClass: "status skip",
        votingPower: "0",
        endpointLabel,
        syncLabel,
        validatorEffective: false,
      };
    }

    return { isActiveParticipant, classify, endpointDiagnostic };
  },
);
