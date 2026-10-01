#!/usr/bin/env python3
"""External workload contract tests; no network or live credentials."""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("public_workload", Path(__file__).resolve().parents[1] / "04-ops/devshard-public-workload.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.config = {"endpoints": {"A": "https://example.test/a", "B": "https://example.test/b"},
                       "secret_files": {"A": "private-a", "B": "private-b"},
                       "creators": {"A": "gonka1aaaa", "B": "gonka1bbbb"},
                       "chain_base": "https://example.test", "lock_directory": str(self.root / "locks")}
        self.calls = []
        self.failure, self.wrong_owner = False, False

    def get(self, base, path):
        if "/balances/" in path:
            return {"balance": {"denom": "ngonka", "amount": "1000000000000000"}}
        if path.endswith("/params"):
            return {"params": {"devshard_escrow_params": {"approved_versions": [
                {"name": "v5", "binary": p.ARCHIVE_URL, "sha256": p.ARCHIVE}]}}}
        if path.endswith("/chain-rpc/status"):
            return {"result": {"node_info": {"network": p.CHAIN}, "sync_info": {"catching_up": False}}}
        if path.endswith("/v1/admission-status"):
            return {"available": True}
        if path.endswith("/v1/status"):
            return {"capacity": {"models": {p.w.MODEL: {"routable": True, "current_weight": 1}}},
                    "devshards": [{"id": "1" if base.endswith("/a") else "2", "active": True,
                        "phase": "active", "requests_blocked": False, "chain_phase": "Inference"}]}
        name = "A" if path.endswith("/1") else "B"
        return {"found": True, "escrow": {"creator": "gonka1wrong" if self.wrong_owner else self.config["creators"][name],
                "model_id": p.w.MODEL, "slots": ["host"]}}

    def send(self, name, wire, deadline, request_id):
        self.calls.append((name, wire, request_id))
        body = {"id": f'devshard-{1 if name == "A" else 2}-{len(self.calls)}', "model": p.w.MODEL,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "fixture answer"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}}
        if json.loads(wire)["stream"]:
            body["choices"][0]["delta"] = body["choices"][0].pop("message")
            encoded = "data: " + json.dumps(body) + "\n\ndata: [DONE]\n\n"
        else:
            encoded = json.dumps(body)
        return {"http_status": 503 if self.failure else 200, "body_complete": True, "transport_error": None,
                "body": encoded, "response_headers": {}, "elapsed_seconds": .1, "ttft_seconds": .05}

    def execute(self, run):
        with patch.object(p.t, "PublicTransport") as transport, patch.object(p, "get_json", self.get), contextlib.redirect_stdout(io.StringIO()):
            transport.return_value.send.side_effect = self.send
            return p.execute(self.config, self.root / "campaign", run)

    def test_two_passes_reuse_corpus_invert_modes_and_attribute_own_escrows(self):
        first, second = self.execute(1), self.execute(2)
        self.assertEqual([first["outcome"], second["outcome"]], ["PASS", "PASS"])
        self.assertEqual(len(self.calls), 80)
        self.assertEqual(first["factual_review"], "PENDING")
        for index in range(40):
            self.assertEqual(first["requests"][index]["case"], second["requests"][index]["case"])
            self.assertNotEqual(first["requests"][index]["stream"], second["requests"][index]["stream"])
        with self.assertRaises(FileExistsError):
            self.execute(1)

    def test_failure_is_retained_and_stops_without_hidden_retry(self):
        self.failure = True
        result = self.execute(1)
        self.assertEqual(result["outcome"], "FAIL")
        self.assertEqual(len(self.calls), 1)
        events = (self.root / "campaign/run-1/events.jsonl").read_text()
        self.assertIn('"http_status": 503', events)
        with self.assertRaises(ValueError):
            self.execute(2)

    def test_wrong_owner_prevents_dispatch(self):
        self.wrong_owner = True
        self.assertEqual(self.execute(1)["outcome"], "FAIL")
        self.assertEqual(self.calls, [])

    def test_shared_endpoint_lock_prevents_overlap_before_dispatch(self):
        locks = Path(self.config["lock_directory"])
        locks.mkdir(mode=0o700)
        path = locks / (hashlib.sha256(self.config["endpoints"]["A"].encode()).hexdigest() + ".lock")
        with path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.execute(1)
        self.assertEqual(self.calls, [])

    def test_phase_and_confirmation_gates(self):
        status = self.get("https://example.test/a", "/v1/status")
        self.assertTrue(p.eligible(status, {"available": True}))
        self.assertFalse(p.eligible(status, {"available": False}))
        status["devshards"][0]["confirmation_poc_phase"] = "CONFIRMATION_POC_GENERATION"
        self.assertFalse(p.eligible(status, {"available": True}))

    def test_preflight_poll_does_not_skip_short_protocol_windows(self):
        with patch.object(p, "eligible", side_effect=[False] + [True] * 40), patch.object(p.time, "sleep") as wait:
            self.assertEqual(self.execute(1)["outcome"], "PASS")
            wait.assert_called_once_with(5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
