#!/usr/bin/env python3
"""Prove the recovery schemas are strict and admit manifest/receipt fixtures."""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]


def load_without_duplicate_keys(path: Path) -> dict:
    def object_pairs(pairs: list[tuple[str, object]]) -> dict:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise AssertionError(f"duplicate JSON key {key!r} in {path}")
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=object_pairs)


manifest_schema = load_without_duplicate_keys(ROOT / "schemas/recovery-manifest-v1.schema.json")
receipt_schema = load_without_duplicate_keys(ROOT / "schemas/recovery-receipt-v1.schema.json")
Draft202012Validator.check_schema(manifest_schema)
Draft202012Validator.check_schema(receipt_schema)


def resolve(node: dict) -> dict:
    if "$ref" not in node:
        return node
    target = manifest_schema
    for part in node["$ref"].removeprefix("#/").split("/"):
        target = target[part]
    return target


def string_value(node: dict) -> str:
    pattern = node.get("pattern", "")
    if pattern == "^[a-f0-9]{64}$":
        return "0" * 64
    if pattern == "^[a-f0-9]{40}$":
        return "0" * 40
    if "A-Fa-f0-9]{40}" in pattern:
        return "0" * 40
    if pattern == "^sha256:[a-f0-9]{64}$":
        return "sha256:" + "0" * 64
    if pattern.startswith("^gonka"):
        return "gonka1" + "q" * 12
    if pattern.startswith("^(?:https?|tcp)://"):
        return "http://node1:26657"
    if "(?:ns|us|ms|s|m|h)" in pattern:
        return "1s"
    if pattern.startswith("^[1-9][0-9]*"):
        return "1"
    if pattern.startswith("^(0|[1-9][0-9]*)"):
        return "0"
    if pattern.startswith("^/") or pattern.startswith("^(?:/"):
        return "/x"
    if pattern == "^[a-z][a-z0-9/]{1,127}$":
        return "ux"
    if node.get("format") == "date-time":
        return "2026-09-13T00:00:00Z"
    if pattern.startswith("^(?:0"):
        return "0.5"
    if "A-Za-z0-9+/" in pattern:
        return "AA=="
    return "x" * max(1, node.get("minLength", 1))


def minimal_instance(raw: dict):
    node = resolve(raw)
    if "const" in node:
        return copy.deepcopy(node["const"])
    if "enum" in node:
        return copy.deepcopy(node["enum"][0])
    if "anyOf" in node:
        for option in node["anyOf"]:
            resolved = resolve(option)
            kind = resolved.get("type")
            if kind == "null" or isinstance(kind, list) and "null" in kind:
                return None
        return minimal_instance(node["anyOf"][0])
    kind = node.get("type")
    if isinstance(kind, list):
        if "null" in kind:
            return None
        kind = kind[0]
    if kind == "object" or "properties" in node:
        return {name: minimal_instance(node["properties"][name]) for name in node.get("required", [])}
    if kind == "array":
        minimum = node.get("minItems", 0)
        if "contains" in node:
            first = minimal_instance(node["contains"])
            return [first] + [minimal_instance(node["items"]) for _ in range(max(0, minimum - 1))]
        return [minimal_instance(node["items"]) for _ in range(minimum)]
    if kind == "integer":
        return node.get("minimum", 0)
    if kind == "boolean":
        return False
    if kind == "null":
        return None
    if kind == "string" or "pattern" in node or "format" in node:
        return string_value(node)
    raise AssertionError(f"no minimal-instance rule for {node}")


validator = Draft202012Validator(
    manifest_schema, format_checker=Draft202012Validator.FORMAT_CHECKER
)
receipt_validator = Draft202012Validator(
    receipt_schema, format_checker=Draft202012Validator.FORMAT_CHECKER
)
draft = minimal_instance(manifest_schema)
# minimal_instance does not evaluate allOf/if-then, so the single generated
# signer_control_entry (classification "controlled") needs its conditionally
# required "host" filled in by hand, same as every other conditional field below.
draft["validator_sets"]["signer_control_matrix"][0]["host"] = "x"
validator.validate(draft)

artifact = {
    "artifact_id": "qualification-1",
    "kind": "qualification_receipt",
    "sha256": "0" * 64,
    "location": "/evidence/qualification.json",
}
key_binding = {
    "key_id": "transition-key",
    "algorithm": "ed25519",
    # Must differ from old_participant_consensus.
    "public_key": "BB==",
    "public_key_sha256": "0" * 64,
    "consensus_address": "1" * 40,
}
final = copy.deepcopy(draft)
final["lifecycle"].update(
    state="final",
    finalized_at="2026-09-13T00:01:00Z",
    preparation_draft_sha256="0" * 64,
)
final["transition"]["new_transition_consensus"] = key_binding
# The transition host ("x") must never coincide with the return cohort (C2);
# the minimal instance otherwise reuses "x" everywhere it needs a host name.
final["hosts"]["return_order"] = ["y"]
# The minimal instance's date-time placeholder is already in the past; a
# ready-to-execute manifest needs a plausible future singleton deadline so
# generic fixtures are not accidentally "expired" (Part D).
final["singleton"]["singleton_deadline_utc"] = "2099-01-01T00:00:00Z"
# HF-01: the sole H+1 validator is classified "lost" with evidence, not
# "controlled" -- a controlled/signing validator would make the single-validator
# fixture trivially "recoverable" and this exact manifest is reused (--emit-final)
# as the shared base fixture for the bash contract suite's quorum-matrix checks.
final["validator_sets"]["signer_control_matrix"][0] = {
    "valoper_address": final["validator_sets"]["next"]["validators"][0]["valoper_address"],
    "classification": "lost",
    "evidence_ref": {**artifact, "artifact_id": "lost-validator-1"},
}
# Likewise every bech32 address defaults to the same placeholder string; a
# retired identity must never coincide with the transition addresses (C1).
final["retirement"]["retired_identities"][0].update(
    participant_address="gonka1" + "z" * 12,
    account_address="gonka1" + "z" * 12,
    valoper_address="gonka1" + "z" * 12,
)
final["first_boundary_policy"]["case_a"].update(
    admitted=True, qualified=True, qualification_receipt=artifact
)
final["retirement"].update(qualified=True, qualification_receipt=artifact)
final["singleton"]["expiry_stop_approval_binding"] = {
    "subject_kind": "final_manifest",
    "subject_sha256": "0" * 64,
    "host": "x",
    "action": "expiry_stop",
    "not_before": "2026-09-13T00:00:00Z",
    "expires_at": "2026-09-13T01:00:00Z",
    "required_signer_key_ids": ["approver"],
    "minimum_signatures": 1,
}
final["approvals"].update(
    trusted_approvers=[
        {
            "key_id": "approver",
            "role": "labteam",
            "algorithm": "sshsig-ed25519",
            "public_key": "ssh-ed25519 " + "A" * 68,
            "public_key_sha256": "0" * 64,
        }
    ],
    phase_policies=[
        {
            "action": "activate",
            "subject_kind": "final_manifest",
            "allowed_hosts": ["x"],
            "required_roles": ["labteam"],
            "minimum_signatures": 1,
            "maximum_age_seconds": 900,
        }
    ],
    qualification_receipts=[artifact],
    review_receipts=[
        {**artifact, "artifact_id": "review-1", "kind": "review_receipt"}
    ],
)
validator.validate(final)

# Checkpoint receipts are a distinct artifact consumed by the rejoin gate.
# Keep the checkpoint payload at the top level (rather than hiding it in the
# generic terminal verdict), and bind it to the same manifest/runtime as the
# receipt itself.  The shell rejoin validator additionally checks the source
# height and the S/S+1/S+2 heights; this fixture contains that full shape.
checkpoint_sha = "1" * 64
checkpoint = {
    "schema_version": 1,
    "kind": "gdc-network-recovery-receipt",
    "receipt_type": "checkpoint",
    "receipt_id": "checkpoint-1",
    "run_id": "run-1",
    "attempt_id": "attempt-1",
    "attempt_number": 1,
    "sequence": 1,
    "manifest_binding_kind": "final_manifest",
    "manifest_sha256": checkpoint_sha,
    "host": "x",
    "phase": "checkpoint",
    "started_at": "2026-09-13T00:00:00Z",
    "finished_at": "2026-09-13T00:00:01Z",
    "command": {
        "selector": "checkpoint",
        "redacted": True,
        "argv_sha256": "2" * 64,
    },
    "exit_status": 0,
    "verdict": "PASS",
    "mutation_state": "committed",
    "observed_hashes": [],
    "evidence": [],
    "next_permitted_steps": ["rejoin"],
    "predecessor_receipts": [],
    "append_only": {
        "immutable": True,
        "attempt_directory": "/var/lib/gdc/runs/run-1/recovery/x/checkpoint/attempt-1",
        "prior_attempt_state": "none",
        "raw_evidence_separate": True,
        "sanitized_receipt": True,
    },
    "details": {
        "state": "CHECKPOINT_READY",
        "reason_code": "checkpoint_captured",
        "message": "checkpoint fixture",
    },
    "checkpoint": {
        "snapshot_height": 101,
        "snapshot_format": 1,
        "snapshot_hash": "3" * 64,
        "snapshot_metadata_sha256": "4" * 64,
        "chunks_verified": True,
        "trust_height": 101,
        "trust_block_hash": "5" * 64,
        "trust_height_equals_snapshot_height": True,
        "supporting_light_blocks": [
            {
                "height": height,
                "block_hash": f"{height:064x}",
                "commit_sha256": "6" * 64,
                "validator_set_sha256": "7" * 64,
                "consensus_params_sha256": "8" * 64,
                "available_until": "2026-09-13T01:00:00Z",
            }
            for height in (101, 102, 103)
        ],
        "observed_at": "2026-09-13T00:00:01Z",
        "expires_at": "2099-09-13T00:00:00Z",
        "source_node_ids": ["a" * 40],
        "rpc_endpoints": ["http://node1:26657"],
        "runtime_sha256": "9" * 64,
        "manifest_sha256": checkpoint_sha,
        "single_source_risk_acceptance_required": False,
        "host_snapshot_interval": 100,
        "host_snapshot_keep_recent": 2,
        "host_min_retain_blocks": 0,
        "snapshot_available_until": "2099-09-13T00:00:00Z",
    },
}
receipt_validator.validate(checkpoint)

for retention_field in ("host_snapshot_interval", "host_snapshot_keep_recent", "host_min_retain_blocks", "snapshot_available_until"):
    missing_retention_field = copy.deepcopy(checkpoint)
    del missing_retention_field["checkpoint"][retention_field]
    assert list(receipt_validator.iter_errors(missing_retention_field)), (
        f"checkpoint must record host retention field {retention_field}"
    )

# E1: schema shape alone admits a would-be-pruned snapshot; the actual
# expiry-ordering gate lives in recovery_validate_checkpoint_semantics.
pruned_before_expiry = copy.deepcopy(checkpoint)
pruned_before_expiry["checkpoint"]["snapshot_available_until"] = "2000-01-01T00:00:00Z"
receipt_validator.validate(pruned_before_expiry)

missing_checkpoint = copy.deepcopy(checkpoint)
del missing_checkpoint["checkpoint"]
assert list(receipt_validator.iter_errors(missing_checkpoint)), (
    "checkpoint receipt must carry a top-level checkpoint payload"
)

# A generic terminal verdict must not be able to masquerade as a checkpoint.
# Test both forms: without a terminal payload and with one (the latter catches
# an accidental relaxation of the receipt-type exclusivity rule).
verdict_with_checkpoint = copy.deepcopy(checkpoint)
verdict_with_checkpoint["receipt_type"] = "verdict"
assert list(receipt_validator.iter_errors(verdict_with_checkpoint)), (
    "generic verdict cannot masquerade as a checkpoint"
)
verdict_with_checkpoint["terminal"] = {
    "scope": "attempt",
    "state": "PASS",
    "reason_code": "checkpoint_fixture",
    "required_receipts": [],
    "evidence_complete": True,
    "incident_closure_authorized": False,
}
assert list(receipt_validator.iter_errors(verdict_with_checkpoint)), (
    "generic verdict cannot carry checkpoint and terminal payloads together"
)

unknown_field = copy.deepcopy(final)
unknown_field["unreviewed_override"] = True
assert list(validator.iter_errors(unknown_field)), "unknown manifest fields must fail closed"

# HF-05 block 1: a full, fresh bounded host inspect must validate, carrying
# per-observation time/source and the richer runtime/signer evidence needed
# to gate prepare and the quorum-recoverable/higher-commit stop conditions.
inspect_receipt = {
    "schema_version": 1,
    "kind": "gdc-network-recovery-receipt",
    "receipt_type": "verdict",
    "receipt_id": "inspect-1",
    "run_id": "run-1",
    "attempt_id": "attempt-1",
    "attempt_number": 1,
    "sequence": 1,
    "manifest_binding_kind": "none",
    "manifest_sha256": None,
    "host": "x",
    "phase": "inspect",
    "started_at": "2026-09-13T00:00:00Z",
    "finished_at": "2026-09-13T00:00:05Z",
    "command": {
        "selector": "inspect",
        "redacted": True,
        "argv_sha256": "2" * 64,
    },
    "exit_status": 0,
    "verdict": "OBSERVED",
    "mutation_state": "none",
    "observed_hashes": [
        {
            "kind": "chain_status",
            "sha256": "1" * 64,
            "observed_at": "2026-09-13T00:00:01Z",
            "source": "ssh:x:status",
        },
        {
            "kind": "validators_h_plus_1",
            "sha256": "2" * 64,
            "height": 307,
            "observed_at": "2026-09-13T00:00:03Z",
            "source": "ssh:x:validators",
        },
    ],
    "evidence": [],
    "next_permitted_steps": [],
    "predecessor_receipts": [],
    "append_only": {
        "immutable": True,
        "attempt_directory": "/var/lib/gdc/runs/run-1/recovery/x/inspect/attempt-1",
        "prior_attempt_state": "none",
        "raw_evidence_separate": True,
        "sanitized_receipt": True,
    },
    "details": {
        "state": "INSPECTED",
        "reason_code": "bounded_host_evidence_complete",
        "message": "bounded host evidence complete",
        "inspection": {
            "chain_id": "gonka-devnet-community",
            "observed_height": 306,
            "source_application_hash": "3" * 64,
            "complete_validator_set_sha256": "4" * 64,
            "runtime_sha256": "5" * 64,
            "public_bindings": [
                {"binding_kind": "consensus_key", "binding_id": "x", "public_value_sha256": "6" * 64}
            ],
            "archive_coverage_verified": True,
            "controller_sha256": "c" * 64,
            "operator_state": "INSPECTED",
            "evidence_complete": True,
            "genesis_sha256": "7" * 64,
            "last_block_hash": "8" * 64,
            "commit_verified": True,
            "validator_set_h_sha256": "9" * 64,
            "runtime_image_digest": "a" * 64,
            "mounts_sha256": "b" * 64,
            "restart_mechanism": "docker_restart_policy",
            "signer_mode": "local_file_pv",
            "priv_validator_laddr": "",
            "tmkms_present": False,
            "evidence_fresh": True,
            "higher_commit_found": False,
            "quorum_recoverable": False,
            "quorum_power": {
                "height": 307,
                "total_power": "135",
                "available_power": "81",
                "strict_required_power": "91",
                "strictly_over_two_thirds": False,
            },
            "observation_started_at": "2026-09-13T00:00:00Z",
            "observation_completed_at": "2026-09-13T00:00:05Z",
        },
    },
    "terminal": {
        "scope": "attempt",
        "state": "INCONCLUSIVE",
        "reason_code": "bounded_host_evidence_complete",
        "required_receipts": [],
        "evidence_complete": True,
        "incident_closure_authorized": False,
    },
}
receipt_validator.validate(inspect_receipt)

bad_signer_mode = copy.deepcopy(inspect_receipt)
bad_signer_mode["details"]["inspection"]["signer_mode"] = "root_shell"
assert list(receipt_validator.iter_errors(bad_signer_mode)), (
    "signer_mode must stay within the reviewed enum"
)

bad_laddr = copy.deepcopy(inspect_receipt)
bad_laddr["details"]["inspection"]["priv_validator_laddr"] = "not-a-laddr"
assert list(receipt_validator.iter_errors(bad_laddr)), (
    "priv_validator_laddr must be empty or a tcp:// address, never a bare string"
)

unknown_inspection_field = copy.deepcopy(inspect_receipt)
unknown_inspection_field["details"]["inspection"]["raw_key_material"] = "should never appear"
assert list(receipt_validator.iter_errors(unknown_inspection_field)), (
    "inspection details reject unknown fields, closing off an accidental key leak"
)

# E4: the coordinator identity hash must be present on every inspect receipt;
# later phases bind their controller_mismatch gate to this exact field.
missing_controller_sha256 = copy.deepcopy(inspect_receipt)
del missing_controller_sha256["details"]["inspection"]["controller_sha256"]
assert list(receipt_validator.iter_errors(missing_controller_sha256)), (
    "inspection details must record controller_sha256"
)

# E2: resume --step signers must report the height its local readback used
# and the addresses it found blocked; the other two steps do not need them.
resume_signers_receipt = copy.deepcopy(inspect_receipt)
resume_signers_receipt["phase"] = "resume"
resume_signers_receipt["step"] = "signers"
resume_signers_receipt["manifest_binding_kind"] = "final_manifest"
resume_signers_receipt["manifest_sha256"] = "0" * 64
resume_signers_receipt["command"]["selector"] = "resume_signers"
resume_signers_receipt["details"] = {
    "state": "SIGNERS_READY",
    "reason_code": "resume_signers_fixture",
    "message": "resume signers fixture",
    "resume": {
        "step": "signers",
        "resources_changed": ["tmkms"],
        "signer_binding_sha256": "d" * 64,
        "duplicate_signer_absent": True,
        "power": {
            "height": 307,
            "total_power": "135",
            "available_power": "91",
            "strict_required_power": "91",
            "strictly_over_two_thirds": False,
        },
        "local_state_height": 400,
        "blocked_participant_addresses": ["gonka1" + "z" * 12],
    },
}
receipt_validator.validate(resume_signers_receipt)
missing_signers_evidence = copy.deepcopy(resume_signers_receipt)
del missing_signers_evidence["details"]["resume"]["blocked_participant_addresses"]
assert list(receipt_validator.iter_errors(missing_signers_evidence)), (
    "resume --step signers must carry blocked_participant_addresses"
)

# E2: rejoin evidence must say whether the returning host shows the
# in-place-testnet fork-replacement log marker.
rejoin_receipt = copy.deepcopy(inspect_receipt)
rejoin_receipt["phase"] = "rejoin"
rejoin_receipt["manifest_binding_kind"] = "final_manifest"
rejoin_receipt["manifest_sha256"] = "0" * 64
rejoin_receipt["command"]["selector"] = "rejoin"
rejoin_receipt["details"] = {
    "state": "REJOINED",
    "reason_code": "rejoin_fixture",
    "message": "rejoin fixture",
    "state_sync": {
        "checkpoint_receipt_sha256": "e" * 64,
        "source_mode": "single-transition-source",
        "source_node_ids": ["a" * 40],
        "restored_snapshot_height": 306620,
        "caught_up": True,
        "common_height": 306621,
        "common_block_hash": "f" * 64,
        "common_application_hash": "1" * 64,
        "retirement_readback_sha256": "2" * 64,
        "fork_replacement_marker_found": False,
    },
}
receipt_validator.validate(rejoin_receipt)
missing_fork_marker = copy.deepcopy(rejoin_receipt)
del missing_fork_marker["details"]["state_sync"]["fork_replacement_marker_found"]
assert list(receipt_validator.iter_errors(missing_fork_marker)), (
    "rejoin state_sync details must record fork_replacement_marker_found"
)

# E1/E3: an approval may accept the single-transition-source risk, and may
# use the reused lab_execution action for an isolated-lab handler run.
lab_approval_receipt = {
    "schema_version": 1,
    "kind": "gdc-network-recovery-receipt",
    "receipt_type": "approval",
    "receipt_id": "lab-approval-1",
    "run_id": "run-1",
    "attempt_id": "attempt-1",
    "attempt_number": 1,
    "sequence": 1,
    "manifest_binding_kind": "final_manifest",
    "manifest_sha256": "0" * 64,
    "host": "x",
    "phase": "rejoin",
    "started_at": "2026-09-13T00:00:00Z",
    "finished_at": "2026-09-13T00:00:01Z",
    "command": {"selector": "rejoin", "redacted": True, "argv_sha256": "2" * 64},
    "exit_status": 0,
    "verdict": "PASS",
    "mutation_state": "none",
    "observed_hashes": [],
    "evidence": [],
    "next_permitted_steps": [],
    "predecessor_receipts": [],
    "append_only": {
        "immutable": True,
        "attempt_directory": "/var/lib/gdc/runs/run-1/recovery/x/rejoin/attempt-1",
        "prior_attempt_state": "none",
        "raw_evidence_separate": True,
        "sanitized_receipt": True,
    },
    "details": {"state": "NEW", "reason_code": "lab_approval_fixture", "message": "lab approval fixture"},
    "approval": {
        "signed_payload": {
            "canonicalization": "jq-cS-utf8-v1",
            "namespace": "gdc-network-recovery-v1",
            "approval_id": "approval-1",
            "run_id": "run-1",
            "subject_kind": "final_manifest",
            "subject_sha256": "0" * 64,
            "action": "lab_execution",
            "host": "x",
            "not_before": "2026-09-13T00:00:00Z",
            "expires_at": "2026-09-13T01:00:00Z",
            "nonce": "nonce-000000000001",
            "single_source_risk_accepted": True,
        },
        "canonical_payload_sha256": "3" * 64,
        "signatures": [
            {
                "key_id": "labteam-1",
                "algorithm": "sshsig-ed25519",
                "namespace": "gdc-network-recovery-v1",
                "armored_signature": "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n",
                "signed_payload_sha256": "3" * 64,
            }
        ],
        "verification": {
            "trusted_approver_set_sha256": "4" * 64,
            "verified_at": "2026-09-13T00:00:01Z",
            "verified_key_ids": ["labteam-1"],
            "required_signatures": 1,
            "cryptographic_threshold_met": True,
            "time_window_valid": True,
            "subject_binding_valid": True,
        },
    },
}
receipt_validator.validate(lab_approval_receipt)
bad_action_approval = copy.deepcopy(lab_approval_receipt)
bad_action_approval["approval"]["signed_payload"]["action"] = "orbit_launch"
assert list(receipt_validator.iter_errors(bad_action_approval)), "approval action stays a closed enum"

# Part D: a singleton-expired status reports EXPIRED with a zero budget,
# not one of the ordinary operator-progress states.
expired_status_receipt = copy.deepcopy(inspect_receipt)
expired_status_receipt["phase"] = "status"
expired_status_receipt["manifest_binding_kind"] = "final_manifest"
expired_status_receipt["manifest_sha256"] = "1" * 64
expired_status_receipt["command"]["selector"] = "status"
expired_status_receipt["details"] = {
    "state": "EXPIRED",
    "reason_code": "singleton_expired",
    "message": "singleton window expired",
    "status": {
        "operator_state": "EXPIRED",
        "runtime_state": "unknown",
        "database_state": "unknown",
        "remaining_seconds": 0,
        "remaining_blocks": 0,
        "missing_gate": "singleton window expired: abort or expiry-stop only",
    },
    "singleton_budget": {
        "first_counted_height": 101,
        "current_height": 5000,
        "remaining_blocks": 0,
        "remaining_seconds": 0,
        "expired": True,
    },
}
receipt_validator.validate(expired_status_receipt)

bad_state_value = copy.deepcopy(expired_status_receipt)
bad_state_value["details"]["state"] = "TIMED_OUT"
assert list(receipt_validator.iter_errors(bad_state_value)), (
    "details.state stays a closed enum; EXPIRED is the only addition"
)

# 5.7 first-boundary gate: A is an empty group, B a single power change.
non_empty_case_a = copy.deepcopy(final)
non_empty_case_a["first_boundary_policy"]["case_a"]["expected_group"] = ["gonka1" + "q" * 12]
assert list(validator.iter_errors(non_empty_case_a)), "case A must reject a non-empty expected group"

# Case B: one power_change only.
case_b_base = copy.deepcopy(final)
case_b_base["first_boundary_policy"]["case_b"]["expected_group"] = ["gonka1" + "q" * 12]
case_b_base["first_boundary_policy"]["case_b"]["allowed_updates"] = [
    {
        "effective_height": 1,
        "operation": "add",
        "consensus": key_binding,
        "power_before": "0",
        "power_after": "1",
    }
]
assert list(validator.iter_errors(case_b_base)), "case B must reject an added validator"
case_b_remove = copy.deepcopy(case_b_base)
case_b_remove["first_boundary_policy"]["case_b"]["allowed_updates"][0]["operation"] = "remove"
assert list(validator.iter_errors(case_b_remove)), "case B must reject a removed validator"

# Exactly one transition host, and it is not also returning.
two_transition_hosts = copy.deepcopy(final)
second_binding = copy.deepcopy(two_transition_hosts["hosts"]["bindings"][0])
second_binding["host"] = "y"
two_transition_hosts["hosts"]["bindings"].append(second_binding)
assert list(validator.iter_errors(two_transition_hosts)), "exactly one host may hold the transition role"

transition_and_returning = copy.deepcopy(final)
transition_and_returning["hosts"]["bindings"][0]["roles"] = ["transition", "returning"]
transition_and_returning["hosts"]["bindings"][0]["return_position"] = 1
assert list(
    validator.iter_errors(transition_and_returning)
), "the transition host cannot also be a returning host"

# 5.1: the recovery target is pinned to the approved devnet chain.
wrong_chain_id = copy.deepcopy(final)
wrong_chain_id["chain"]["chain_id"] = "some-other-chain"
assert list(validator.iter_errors(wrong_chain_id)), "chain_id must be pinned to the approved devnet chain"

empty_return_order = copy.deepcopy(final)
empty_return_order["hosts"]["return_order"] = []
assert list(validator.iter_errors(empty_return_order)), "return_order must name at least one returning host"

# E4: the coordinator identity hash pins a final manifest to one operator
# machine; every phase after prepare refuses controller_mismatch without it.
missing_coordinator = copy.deepcopy(final)
del missing_coordinator["coordinator_sha256"]
assert list(validator.iter_errors(missing_coordinator)), "coordinator_sha256 is required"

# E3: execution.scope is a closed enum, and only working_network/isolated_lab
# make sense; lab_hosts must be empty outside an isolated lab.
bad_execution_scope = copy.deepcopy(final)
bad_execution_scope["execution"]["scope"] = "anywhere"
assert list(validator.iter_errors(bad_execution_scope)), "execution.scope stays a closed enum"
lab_hosts_outside_lab = copy.deepcopy(final)
lab_hosts_outside_lab["execution"]["lab_hosts"] = ["y"]
assert list(validator.iter_errors(lab_hosts_outside_lab)), (
    "lab_hosts must stay empty when execution.scope is working_network"
)
bad_supervised_selector = copy.deepcopy(final)
bad_supervised_selector["execution"]["supervised_live_allowed_selectors"] = ["activate"]
assert list(validator.iter_errors(bad_supervised_selector)), (
    "supervised_live_allowed_selectors admits only resume_poc/resume_handoff"
)

# HF-01: every H+1 validator needs exactly one signer-control classification,
# and each classification carries the evidence its case requires.
controlled_without_host = copy.deepcopy(final)
del controlled_without_host["validator_sets"]["signer_control_matrix"][0]["evidence_ref"]
controlled_without_host["validator_sets"]["signer_control_matrix"][0]["classification"] = "controlled"
assert list(validator.iter_errors(controlled_without_host)), (
    "a controlled validator must name its host"
)
lost_without_evidence = copy.deepcopy(final)
del lost_without_evidence["validator_sets"]["signer_control_matrix"][0]["evidence_ref"]
assert list(validator.iter_errors(lost_without_evidence)), (
    "a lost validator must carry an evidence_ref"
)

# E3: a manifest may opt an approval into the reused lab_execution action
# (checked below on a full approval receipt, not just this policy shape).
lab_execution_policy = copy.deepcopy(final)
lab_execution_policy["approvals"]["phase_policies"][0]["action"] = "lab_execution"
validator.validate(lab_execution_policy)

if len(sys.argv) == 3 and sys.argv[1] == "--emit-final":
    Path(sys.argv[2]).write_text(json.dumps(final, indent=2) + "\n", encoding="utf-8")
elif len(sys.argv) != 1:
    raise SystemExit("usage: test-network-recovery-schemas.py [--emit-final PATH]")

print("PASS recovery schemas admit strict draft/final manifests and reject unknown fields")
