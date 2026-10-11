// Generated from src/network-observation-state.js - edit the Flow source and run make site-js

const VALIDATOR_PAGE_SIZE = 100;
const MAX_VALIDATOR_COUNT = 10000;
const MAX_REFERENCE_AGE_MS = 90000;
const PARTICIPANT_PAGE_SIZE = 100;
const MAX_PARTICIPANTS = 10000;
const MAX_PARTICIPANT_PAGES = 100;

(function attachNetworkObservationState(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_NETWORK_OBSERVATION = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function networkObservationStateFactory() {
    function nodeState(observation) {
      const nodeId = String(observation?.node_id || "");
      if (!/^[0-9a-f]{40}$/.test(nodeId)) return null;
      const active = observation?.active === true;
      const dapiUrl =
        typeof observation?.dapi_url === "string" ? observation.dapi_url : "";
      const nodeName =
        typeof observation?.node_name === "string" ? observation.node_name : "";
      const rpc = observation?.components?.chain_rpc;
      const error = String(rpc?.error || observation?.error || "");
      return {
        nodeId,
        nodeName,
        dapiUrl,
        active,
        endpointState:
          rpc?.state === "observed"
            ? "reachable"
            : rpc?.state === "unavailable"
              ? "unavailable"
              : "unknown",
        endpointDiagnostic: error,
        catchingUp: observation?.components?.chain_rpc?.catching_up === true,
      };
    }
    async function observeRpc(base, nodeId, getJson) {
      const [status, peers] = await Promise.all([
        getJson(`${base}/chain-rpc/status`),
        getJson(`${base}/chain-rpc/net_info`).catch(() => null),
      ]);
      if (nodeId && status?.result?.node_info?.id !== nodeId)
        throw new Error("RPC node identity mismatch");
      return { status, peers };
    }
    async function loadCurrentValidatorSet(
      reference,
      expectedChainId,
      getJson,
    ) {
      const nowMs = Date.now();
      const nodeId = String(reference?.nodeId || "").toUpperCase();
      const referenceAgeMs = nowMs - Number(reference?.blockTimeMs);
      if (
        !reference?.statusBase ||
        reference.identityVerified !== true ||
        !/^[0-9A-F]{40}$/.test(nodeId)
      )
        throw new Error(
          "identity-verified progressing peer RPC is unavailable",
        );
      if (
        !Number.isSafeInteger(reference.height) ||
        reference.height <= 0 ||
        !expectedChainId ||
        reference.chainId !== expectedChainId ||
        reference.catchingUp !== false ||
        !Number.isFinite(reference.blockTimeMs) ||
        referenceAgeMs < 0 ||
        referenceAgeMs > MAX_REFERENCE_AGE_MS
      )
        throw new Error("fresh verified reference height is unavailable");

      const validatorRpcBase = String(
        reference.validatorRpcBase || reference.statusBase,
      );
      const assertFreshSamePeerStatus = async (
        height,
        statusBase,
        exactHeight,
      ) => {
        const status = await getJson(`${statusBase}/chain-rpc/status`);
        const result = status?.result;
        const observedNodeId = String(
          result?.node_info?.id || "",
        ).toUpperCase();
        const observedChainId = String(result?.node_info?.network || "");
        const observedHeight = Number(result?.sync_info?.latest_block_height);
        const blockTimeMs = Date.parse(
          String(result?.sync_info?.latest_block_time || ""),
        );
        const ageMs = Date.now() - blockTimeMs;
        if (
          observedNodeId !== nodeId ||
          observedChainId !== expectedChainId ||
          result?.sync_info?.catching_up !== false ||
          !Number.isSafeInteger(observedHeight) ||
          observedHeight <= 0 ||
          (exactHeight
            ? observedHeight !== height || height !== reference.height
            : observedHeight < height) ||
          !Number.isFinite(blockTimeMs) ||
          ageMs < 0 ||
          ageMs > MAX_REFERENCE_AGE_MS
        )
          throw new Error(
            "validator set no longer matches a fresh same-peer chain status",
          );
      };

      const makeVerifiedSet = (response, maxCount) => {
        const result = response?.result;
        const entries = Array.isArray(result?.validators)
          ? result.validators
          : [];
        const total = Number(result?.total);
        const count = Number(result?.count);
        const blockHeight = Number(result?.block_height);
        if (
          !Number.isSafeInteger(total) ||
          total <= 0 ||
          total > maxCount ||
          !Number.isSafeInteger(count) ||
          count !== entries.length ||
          total !== entries.length ||
          !Number.isSafeInteger(blockHeight) ||
          blockHeight !== reference.height
        )
          throw new Error(
            "validator response is incomplete or not bound to the sampled height",
          );
        const set = validatorSet(
          response,
          reference.height,
          expectedChainId,
          reference.chainId,
        );
        if (!set.verified)
          throw new Error(
            "validator response contains invalid or duplicate entries",
          );
        return set;
      };

      const validators = [];
      let expectedTotal = 0;
      const pageCount = (total) => Math.ceil(total / VALIDATOR_PAGE_SIZE);
      const pinnedUrl = `${validatorRpcBase}/chain-rpc/validators?height=${reference.height}&page=1&per_page=${VALIDATOR_PAGE_SIZE}`;
      let firstPage;
      try {
        firstPage = await getJson(pinnedUrl);
      } catch (error) {
        // Older same-origin trusted preview guards only permit this unpinned
        // route. Fall back only before collecting page data; catalog-bound
        // public RPCs must support pinned queries. All proof fields are still
        // checked below, and other errors remain failures.
        const errorMessage =
          error instanceof Error ? error.message : String(error);
        if (!/^\s*404\s*$/.test(errorMessage)) throw error;
        if (validatorRpcBase !== reference.statusBase)
          throw new Error(
            "catalog-bound peer RPC does not support pinned validator queries",
          );
        const legacyResponse = await getJson(
          `${validatorRpcBase}/chain-rpc/validators?per_page=${VALIDATOR_PAGE_SIZE}`,
        );
        const legacySet = makeVerifiedSet(legacyResponse, VALIDATOR_PAGE_SIZE);
        await assertFreshSamePeerStatus(
          legacySet.blockHeight,
          reference.statusBase,
          true,
        );
        return legacySet;
      }
      for (let page = 1; ; page += 1) {
        const response =
          page === 1
            ? firstPage
            : await getJson(
                `${validatorRpcBase}/chain-rpc/validators?height=${reference.height}&page=${page}&per_page=${VALIDATOR_PAGE_SIZE}`,
              );
        const result = response?.result;
        const entries = Array.isArray(result?.validators)
          ? result.validators
          : [];
        const total = Number(result?.total);
        const count = Number(result?.count);
        const blockHeight = Number(result?.block_height);
        if (
          !Number.isSafeInteger(total) ||
          total <= 0 ||
          total > MAX_VALIDATOR_COUNT ||
          !Number.isSafeInteger(count) ||
          count !== entries.length ||
          !Number.isSafeInteger(blockHeight) ||
          blockHeight !== reference.height
        ) {
          throw new Error(
            "validator page is incomplete or not bound to the sampled height",
          );
        }
        if (expectedTotal === 0) expectedTotal = total;
        if (
          total !== expectedTotal ||
          entries.length !==
            Math.min(VALIDATOR_PAGE_SIZE, expectedTotal - validators.length)
        )
          throw new Error(
            "validator pagination changed total or returned a partial page",
          );
        validators.push(...entries);
        if (page === pageCount(expectedTotal)) break;
      }
      const completeSet = makeVerifiedSet(
        {
          result: {
            block_height: reference.height,
            count: validators.length,
            total: expectedTotal,
            validators,
          },
        },
        MAX_VALIDATOR_COUNT,
      );
      if (validatorRpcBase !== reference.statusBase)
        await assertFreshSamePeerStatus(
          reference.height,
          validatorRpcBase,
          false,
        );
      return completeSet;
    }
    async function verifyChainApiReference(
      apiOrigin,
      reference,
      expectedChainId,
      getJson,
    ) {
      const nodeId = String(reference?.nodeId || "").toUpperCase();
      if (
        !apiOrigin ||
        reference?.identityVerified !== true ||
        !/^[0-9A-F]{40}$/.test(nodeId) ||
        reference?.chainId !== expectedChainId ||
        !expectedChainId
      )
        throw new Error("identity-verified chain API reference is unavailable");
      const statusUrl = `${apiOrigin}/chain-rpc/status`;
      const status = await getJson(statusUrl);
      const result = status?.result;
      const observedId = String(result?.node_info?.id || "").toUpperCase();
      const chainId = String(result?.node_info?.network || "");
      const height = Number(result?.sync_info?.latest_block_height);
      const blockTimeMs = Date.parse(
        String(result?.sync_info?.latest_block_time || ""),
      );
      const ageMs = Date.now() - blockTimeMs;
      if (
        observedId !== nodeId ||
        chainId !== expectedChainId ||
        result?.sync_info?.catching_up !== false ||
        !Number.isSafeInteger(height) ||
        height <= 0 ||
        !Number.isFinite(blockTimeMs) ||
        ageMs < 0 ||
        ageMs > MAX_REFERENCE_AGE_MS
      )
        throw new Error(
          "chain API reference identity or freshness is unavailable",
        );
      return height;
    }
    async function loadParticipants(
      apiOrigin,
      reference,
      expectedChainId,
      getJson,
    ) {
      await verifyChainApiReference(
        apiOrigin,
        reference,
        expectedChainId,
        getJson,
      );

      const participants = [];
      const seenKeys = new Set();
      let key = "";
      let pageHeight = null;
      for (let page = 0; page < MAX_PARTICIPANT_PAGES; page += 1) {
        const query = new URLSearchParams({
          "pagination.limit": String(PARTICIPANT_PAGE_SIZE),
        });
        if (key) query.set("pagination.key", key);
        const response = await getJson(
          `${apiOrigin}/chain-api/productscience/inference/inference/participant?${query.toString()}`,
        );
        const pageResult = response?.participant;
        const pagination = response?.pagination;
        const currentHeight = Number(response?.block_height);
        if (
          !Array.isArray(pageResult) ||
          !pagination ||
          !Number.isSafeInteger(currentHeight) ||
          currentHeight <= 0 ||
          (pageHeight !== null && currentHeight !== pageHeight)
        )
          throw new Error(
            "participant response is malformed, partial, or changed height",
          );
        if (participants.length + pageResult.length > MAX_PARTICIPANTS)
          throw new Error(
            "participant response exceeds the bounded inventory size",
          );
        for (const participant of pageResult) {
          const address = String(participant?.address || "").trim();
          const index = String(participant?.index || "").trim();
          if (
            !/^gonka1[0-9a-z]{20,}$/i.test(address) ||
            index !== address ||
            typeof participant?.inference_url !== "string" ||
            !participant.inference_url.trim()
          )
            throw new Error(
              "participant page contains an invalid identity record",
            );
          participants.push(participant);
        }
        pageHeight = currentHeight;
        if (!pagination.hasOwnProperty("next_key"))
          throw new Error("participant pagination continuation is missing");
        const nextKey = pagination.next_key;
        if (nextKey === null || nextKey === undefined || nextKey === "") {
          const finalHeight = await verifyChainApiReference(
            apiOrigin,
            reference,
            expectedChainId,
            getJson,
          );
          if (pageHeight !== null && pageHeight > finalHeight)
            throw new Error(
              "participant response advanced beyond the verified peer height",
            );
          return participants;
        }
        if (
          typeof nextKey !== "string" ||
          pageResult.length !== PARTICIPANT_PAGE_SIZE ||
          seenKeys.has(nextKey)
        )
          throw new Error(
            "participant pagination key is malformed or repeated",
          );
        seenKeys.add(nextKey);
        key = nextKey;
      }
      throw new Error("participant pagination exceeded the bounded page count");
    }
    function participantAddressForNode(participants, node) {
      if (
        !Array.isArray(participants) ||
        !node ||
        !/^[0-9a-f]{40}$/.test(String(node.address || "")) ||
        node.rpcIdentityVerified !== true ||
        !node.dapiUrl
      )
        return null;
      let targetOrigin;
      try {
        const target = new URL(String(node.dapiUrl));
        if (
          target.protocol !== "https:" ||
          target.username ||
          target.password ||
          target.pathname !== "/" ||
          target.search ||
          target.hash
        )
          return null;
        targetOrigin = target.origin;
      } catch {
        return null;
      }
      const matches = participants.filter((participant) => {
        try {
          const url = new URL(String(participant?.inference_url || ""));
          return (
            url.protocol === "https:" &&
            !url.username &&
            !url.password &&
            url.pathname === "/" &&
            !url.search &&
            !url.hash &&
            url.origin === targetOrigin &&
            participant?.index === participant?.address
          );
        } catch {
          return false;
        }
      });
      return matches.length === 1 ? String(matches[0].address) : null;
    }
    function peerCount(observation) {
      const raw = observation?.result?.n_peers;
      if (raw === null || raw === undefined || String(raw).trim() === "")
        return "–";
      const count = Number(raw);
      return Number.isSafeInteger(count) && count >= 0 ? String(count) : "–";
    }
    function currentVotingPower(nodeAddress, validatorSet) {
      if (
        validatorSet?.state !== "observed" ||
        validatorSet?.verified !== true ||
        validatorSet?.complete !== true ||
        !Array.isArray(validatorSet.validators)
      )
        return null;
      const address = String(nodeAddress || "")
        .trim()
        .toUpperCase();
      if (!/^[0-9A-F]{40}$/.test(address)) return null;
      const seen = new Set();
      for (const entry of validatorSet.validators) {
        const entryAddress = String(entry?.address || "")
          .trim()
          .toUpperCase();
        const power = String(entry?.voting_power ?? "");
        if (
          !/^[0-9A-F]{40}$/.test(entryAddress) ||
          !/^\d+$/.test(power) ||
          seen.has(entryAddress)
        )
          return null;
        seen.add(entryAddress);
      }
      const validator = validatorSet.validators.find(
        (entry) => String(entry.address).trim().toUpperCase() === address,
      );
      return validator ? String(validator.voting_power) : "0";
    }
    function applyCurrentVotingPower(node, validatorSet) {
      const votingPower = currentVotingPower(
        node?.validatorAddress,
        validatorSet,
      );
      node.validatorKnown = votingPower !== null;
      node.votingPower = votingPower === null ? undefined : votingPower;
      return votingPower;
    }
    function validatorSet(
      response,
      referenceHeight,
      expectedChainId,
      observedChainId,
    ) {
      const result = response?.result;
      const validators = Array.isArray(result?.validators)
        ? result.validators
        : [];
      const total = Number(result?.total);
      const count = Number(result?.count);
      const blockHeight = Number(result?.block_height);
      const seen = new Set();
      const validEntries = validators.every((entry) => {
        const address = String(entry?.address || "")
          .trim()
          .toUpperCase();
        const power = String(entry?.voting_power ?? "");
        if (
          !/^[0-9A-F]{40}$/.test(address) ||
          !/^\d+$/.test(power) ||
          seen.has(address)
        )
          return false;
        seen.add(address);
        return true;
      });
      const complete =
        Number.isSafeInteger(referenceHeight) &&
        referenceHeight > 0 &&
        expectedChainId !== "" &&
        expectedChainId === observedChainId &&
        Number.isSafeInteger(blockHeight) &&
        blockHeight === referenceHeight &&
        Number.isSafeInteger(total) &&
        total > 0 &&
        total <= MAX_VALIDATOR_COUNT &&
        Number.isSafeInteger(count) &&
        total === validators.length &&
        count === validators.length &&
        validEntries;
      return {
        state: "observed",
        verified: complete,
        complete,
        blockHeight,
        chainId: observedChainId,
        validators,
      };
    }
    function referenceProgressed(previous, height, chainId, nowMs, maxAgeMs) {
      const maxAge = maxAgeMs === undefined ? 90000 : maxAgeMs;
      return (
        Number.isSafeInteger(previous?.height) &&
        Number.isSafeInteger(height) &&
        previous?.chainId === chainId &&
        chainId !== "" &&
        height > previous.height &&
        Number.isFinite(previous?.observedAt) &&
        nowMs >= previous.observedAt &&
        nowMs - previous.observedAt <= maxAge
      );
    }
    function selectProgressingReference(
      samples,
      previousByNode,
      expectedChainId,
      nowMs,
    ) {
      return selectFreshReference(
        samples.filter((sample) =>
          referenceProgressed(
            previousByNode.get(String(sample?.nodeId || "").toUpperCase()),
            Number(sample?.height),
            expectedChainId,
            nowMs,
          ),
        ),
        expectedChainId,
        nowMs,
      );
    }
    // A current set is a height-bound observation, not a liveness experiment.
    // It does not require waiting for a second browser polling interval.
    function selectFreshReference(samples, expectedChainId, nowMs) {
      const candidates = samples.filter((sample) => {
        const nodeId = String(sample?.nodeId || "").toUpperCase();
        const height = Number(sample?.height);
        const blockTimeMs = Number(sample?.blockTimeMs);
        const ageSeconds = (nowMs - blockTimeMs) / 1000;
        return (
          Boolean(sample?.statusBase) &&
          sample?.identityVerified === true &&
          /^[0-9A-F]{40}$/.test(nodeId) &&
          sample?.chainId === expectedChainId &&
          expectedChainId !== "" &&
          Number.isSafeInteger(height) &&
          height > 0 &&
          sample?.catchingUp === false &&
          Number.isFinite(ageSeconds) &&
          ageSeconds >= 0 &&
          ageSeconds <= 90
        );
      });
      candidates.sort(
        (left, right) => Number(right.height) - Number(left.height),
      );
      return candidates[0] || null;
    }
    function effectiveValidatorCount(states) {
      return states.filter((state) => state?.validatorEffective === true)
        .length;
    }
    async function loadActivity(base, getJson) {
      const api = `${base}/chain-api/productscience/inference/inference`;
      const epoch = await getJson(`${api}/epoch_info`);
      const stage = String(epoch?.latest_epoch?.poc_start_block_height || "");
      const epochIndex = String(epoch?.latest_epoch?.index || "");
      if (!/^[1-9]\d*$/.test(stage) || !/^[1-9]\d*$/.test(epochIndex))
        throw new Error("epoch information is not reported");
      const readStage = async (height) => {
        const [commits, votes] = await Promise.all([
          getJson(`${api}/all_poc_v2_store_commits/${height}`).catch(
            () => null,
          ),
          getJson(`${api}/poc_v2_validations_for_stage/${height}`).catch(
            () => null,
          ),
        ]);
        return {
          height,
          commits: Array.isArray(commits?.commits) ? commits.commits : null,
          votes: Array.isArray(votes?.poc_validation)
            ? votes.poc_validation
            : null,
        };
      };
      const event = epoch.active_confirmation_poc_event;
      const confirmationStage = String(event?.generation_start_height || "");
      const [poc, cpoc] = await Promise.all([
        readStage(stage),
        epoch.is_confirmation_poc_active === true &&
        /^[1-9]\d*$/.test(confirmationStage)
          ? readStage(confirmationStage)
          : Promise.resolve(null),
      ]);
      return {
        observedAt: Date.now(),
        epoch: epochIndex,
        poc,
        cpoc,
        confirmationActive: epoch.is_confirmation_poc_active,
        confirmationPhase: String(event?.phase || "").replace(
          /^CONFIRMATION_POC_/,
          "",
        ),
      };
    }
    function activityState(evidence, participant, nowMs) {
      const now = nowMs === undefined ? Date.now() : nowMs;
      const unknown = (reason) => ({ label: "Not reported", detail: reason });
      if (!participant)
        return {
          poc: unknown(
            "Participant identity is not uniquely mapped to this endpoint",
          ),
          cpoc: unknown(
            "Participant identity is not uniquely mapped to this endpoint",
          ),
        };
      if (
        !evidence ||
        !Number.isFinite(evidence.observedAt) ||
        now < evidence.observedAt ||
        now - evidence.observedAt > 90000
      )
        return {
          poc: unknown("No recent PoC observation"),
          cpoc: unknown("No recent cPoC observation"),
        };
      const summarize = (stage) => {
        if (!stage) return unknown("Stage data is not reported");
        const commits = stage.commits?.filter(
          (commit) => commit.participant_address === participant,
        );
        const votes = stage.votes
          ?.flatMap((group) =>
            Array.isArray(group?.poc_validation) ? group.poc_validation : [],
          )
          .filter(
            (vote) =>
              vote.participant_address === participant &&
              String(vote.poc_stage_start_block_height) === stage.height,
          );
        const accepted =
          votes?.filter(
            (vote) =>
              /^\d+$/.test(String(vote.validated_weight)) &&
              BigInt(vote.validated_weight) > 0n,
          ).length || 0;
        const rejected =
          votes?.filter((vote) => String(vote.validated_weight) === "-1")
            .length || 0;
        const label =
          accepted || rejected
            ? `${accepted} accept · ${rejected} reject`
            : commits?.length
              ? "Committed"
              : commits
                ? "No commit yet"
                : "Not reported";
        return {
          label,
          detail: `Epoch ${evidence.epoch}; stage ${stage.height}; ${commits?.length ?? "unknown"} model commits; ${votes?.length ?? "unknown"} validation votes; votes are not the final chain decision`,
        };
      };
      return {
        poc: summarize(evidence.poc),
        cpoc:
          evidence.confirmationActive === false
            ? {
                label: "No active event",
                detail: `Epoch ${evidence.epoch}; no cPoC event is active; this does not mean the node is unavailable`,
              }
            : evidence.confirmationActive === true
              ? {
                  ...summarize(evidence.cpoc),
                  detail: `${summarize(evidence.cpoc).detail}; network phase ${evidence.confirmationPhase || "not reported"}`,
                }
              : unknown("Active cPoC event is not reported"),
      };
    }
    function inferenceState(health) {
      if (health?.state !== "observed" || !Array.isArray(health.runtimes))
        return {
          label: "Not reported",
          detail:
            "Per-node inference readiness is not reported; no inference request was sent",
        };
      const running = health.runtimes.filter(
        (runtime) => runtime?.status === "running",
      );
      return {
        label: running.length ? "Runtime running" : "No runtime",
        detail: running.length
          ? `${running.length} running DevShard runtime(s); ML capacity and a successful inference request are not verified by this health endpoint`
          : "DevShard health reports no running runtime; this does not describe PoC or validator membership",
      };
    }
    return {
      nodeState,
      observeRpc,
      peerCount,
      loadCurrentValidatorSet,
      loadParticipants,
      verifyChainApiReference,
      participantAddressForNode,
      currentVotingPower,
      applyCurrentVotingPower,
      validatorSet,
      referenceProgressed,
      selectProgressingReference,
      selectFreshReference,
      effectiveValidatorCount,
      loadActivity,
      activityState,
      inferenceState,
    };
  },
);
