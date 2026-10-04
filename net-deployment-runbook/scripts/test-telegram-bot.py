#!/usr/bin/env python3

import importlib.util
import json
import os
import sqlite3
import tempfile
import threading
import unittest
from email.message import Message
from pathlib import Path
from unittest.mock import call, patch
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


TEMP = tempfile.TemporaryDirectory()
ROOT = Path(TEMP.name)
os.environ.update({
    "TELEGRAM_BOT_TOKEN": "test-token",
    "GATEWAY_API_KEY": "test-client-key",
    "INTERNAL_API_TOKEN": "test-internal-token",
    "STATE_DB": str(ROOT / "bot.sqlite3"),
    "METRICS_FILE": str(ROOT / "telegram-bot.prom"),
})
PROGRAM = Path(__file__).parent / "telegram-bot" / "bot.py"
SPEC = importlib.util.spec_from_file_location("telegram_consumer", PROGRAM)
BOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOT)


class FakeResponse:
    def __init__(self, payload, status=200):
        self.payload = payload
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps(self.payload).encode()


class FakeMalformedResponse(FakeResponse):
    def read(self):
        return b"{"


class TelegramConsumerTest(unittest.TestCase):
    def setUp(self):
        BOT.clear_route_control()
        BOT._backend_cursor = 0
        if BOT.DB_FILE.exists():
            BOT.DB_FILE.unlink()
        if BOT.METRICS_FILE.exists():
            BOT.METRICS_FILE.unlink()

    def admission_ready(self):
        return patch.object(BOT, "require_gateway_admission")

    def ab_backends(self):
        return [
            {"name": "A", "base_url": "https://a.example/v1", "admission_url": "https://a.example/v1/admission-status", "api_key": "devnet_a"},
            {"name": "B", "base_url": "https://b.example/v1", "admission_url": "https://b.example/v1/admission-status", "api_key": "devnet_b"},
        ]

    def test_conversation_is_reused_and_reset_without_key_issuance_tables(self):
        with BOT.connection() as db:
            first = BOT.create_conversation(db, 42)
            self.assertEqual(BOT.create_conversation(db, 42), first)
            second = BOT.reset_user_conversation(db, 42)
            self.assertNotEqual(second, first)
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            self.assertNotIn("keys", tables)

    def test_gateway_completion_persists_history_and_exact_usage_metrics(self):
        payload = {
            "choices": [{"message": {"content": "GDC_OK"}}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 2, "total_tokens": 9},
        }
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 43)
            with self.admission_ready(), patch.object(BOT, "urlopen", return_value=FakeResponse(payload)):
                response = BOT.gateway_completion(db, conversation, "hello")
            self.assertEqual(response["status"], "completed")
            self.assertEqual(response["output_text"], "GDC_OK")
            self.assertEqual(response["usage"]["total_tokens"], 9)
            self.assertEqual(db.execute("SELECT count(*) FROM messages").fetchone()[0], 2)
        metrics = BOT.METRICS_FILE.read_text()
        self.assertIn('gdc_telegram_bot_tokens_total{direction="input",model="Qwen/Qwen3-0.6B"} 7', metrics)
        self.assertIn('gdc_telegram_bot_tokens_total{direction="output",model="Qwen/Qwen3-0.6B"} 2', metrics)
        self.assertIn('gdc_telegram_bot_inference_requests_total{model="Qwen/Qwen3-0.6B",outcome="success"} 1', metrics)
        self.assertIn('gdc_telegram_bot_usage_missing_total{model="Qwen/Qwen3-0.6B"} 0', metrics)

    def test_gateway_completion_removes_think_blocks_before_persistence_and_delivery(self):
        payload = {
            "choices": [{"message": {"content": "<think>\nprivate reasoning\n</think>\n\nThe visible answer"}}],
            "usage": {"prompt_tokens": 8, "completion_tokens": 6, "total_tokens": 14},
        }
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 44)
            with self.admission_ready(), patch.object(BOT, "urlopen", return_value=FakeResponse(payload)):
                response = BOT.gateway_completion(db, conversation, "hello")
            assistant = db.execute(
                "SELECT content FROM messages WHERE conversation_id = ? AND role = 'assistant'",
                (conversation,),
            ).fetchone()["content"]
        self.assertEqual(response["output_text"], "The visible answer")
        self.assertEqual(assistant, "The visible answer")
        self.assertNotIn("private reasoning", response["output_text"])

    def test_gateway_completion_classifies_malformed_json_as_invalid_response(self):
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 45)
            with self.admission_ready(), patch.object(BOT, "urlopen", return_value=FakeMalformedResponse(None)):
                with self.assertRaisesRegex(RuntimeError, "gateway returned invalid JSON"):
                    BOT.gateway_completion(db, conversation, "hello")
            outcome = db.execute(
                "SELECT outcome FROM inference_events ORDER BY id DESC LIMIT 1"
            ).fetchone()["outcome"]
        self.assertEqual(outcome, "invalid_response")

    def test_gateway_completion_exposes_only_proven_pre_dispatch_rejection_for_retry(self):
        headers = Message()
        headers["X-GDC-Admission"] = "pre_dispatch_rejected"
        error = HTTPError("https://api.example/v1/chat/completions", 503, "Unavailable", headers, None)
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 46)
            with self.admission_ready(), patch.object(BOT, "urlopen", side_effect=error):
                with self.assertRaisesRegex(RuntimeError, "gateway pre dispatch rejected"):
                    BOT.gateway_completion(db, conversation, "hello")
            outcome = db.execute(
                "SELECT outcome FROM inference_events ORDER BY id DESC LIMIT 1"
            ).fetchone()["outcome"]
        self.assertEqual(outcome, "pre_dispatch_http_503")

    def test_gateway_completion_does_not_make_dispatched_failure_retryable(self):
        headers = Message()
        headers["X-GDC-Admission"] = "dispatched_once"
        error = HTTPError("https://api.example/v1/chat/completions", 503, "Unavailable", headers, None)
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 47)
            with self.admission_ready(), patch.object(BOT, "urlopen", side_effect=error):
                with self.assertRaisesRegex(RuntimeError, "gateway returned HTTP 503"):
                    BOT.gateway_completion(db, conversation, "hello")
            outcome = db.execute(
                "SELECT outcome FROM inference_events ORDER BY id DESC LIMIT 1"
            ).fetchone()["outcome"]
        self.assertEqual(outcome, "http_503")

    def test_gateway_completion_rotates_a_then_b_and_records_backend(self):
        payload = {"choices": [{"message": {"content": "GDC_OK"}}]}
        requested = []

        def response(request, timeout):
            requested.append((request.full_url, timeout))
            return FakeResponse(payload)

        BOT._backend_cursor = 0
        with BOT.connection() as db, patch.object(BOT, "GATEWAY_BACKENDS", self.ab_backends()), self.admission_ready(), patch.object(
            BOT, "urlopen", side_effect=response
        ):
            BOT.gateway_completion(db, BOT.create_conversation(db, 48), "first")
            BOT.gateway_completion(db, BOT.create_conversation(db, 49), "second")
            selected = [row["backend"] for row in db.execute(
                "SELECT backend FROM inference_events WHERE outcome = 'success' ORDER BY id"
            )]
        self.assertEqual([url for url, _timeout in requested], [
            "https://a.example/v1/chat/completions", "https://b.example/v1/chat/completions",
        ])
        self.assertEqual(selected, ["A", "B"])

    def test_gateway_completion_uses_one_alternate_after_pre_dispatch_rejection(self):
        payload = {"choices": [{"message": {"content": "GDC_OK"}}]}
        admission_attempts = []

        def admission(_db, backend, *_args):
            admission_attempts.append(backend["name"])
            if backend["name"] == "A":
                raise BOT.GatewayPreDispatchRejected("unavailable")

        BOT._backend_cursor = 0
        with BOT.connection() as db, patch.object(BOT, "GATEWAY_BACKENDS", self.ab_backends()), patch.object(
            BOT, "require_gateway_admission", side_effect=admission
        ), patch.object(BOT, "urlopen", return_value=FakeResponse(payload)) as request:
            response = BOT.gateway_completion(db, BOT.create_conversation(db, 50), "fallback")
        self.assertEqual(response["output_text"], "GDC_OK")
        self.assertEqual(admission_attempts, ["A", "B"])
        self.assertEqual(request.call_args.args[0].full_url, "https://b.example/v1/chat/completions")

    def test_route_control_forces_one_pre_dispatch_fallback_without_contacting_disabled_gateway(self):
        payload = {"choices": [{"message": {"content": "GDC_OK"}}]}

        def response(request, timeout):
            if request.full_url.endswith("/admission-status"):
                return FakeResponse({"available": True})
            return FakeResponse(payload)

        with patch.object(BOT, "GATEWAY_BACKENDS", self.ab_backends()):
            controls = BOT.set_route_control({
                "disabled_backends": ["A"], "force_next_backend": "A", "ttl_seconds": 60,
            })
            self.assertEqual(controls["disabled_backends"], ("A",))
            self.assertEqual(controls["force_next_backend"], "A")
            with BOT.connection() as db, patch.object(BOT, "urlopen", side_effect=response) as request:
                response = BOT.gateway_completion(db, BOT.create_conversation(db, 501), "fallback")
                events = [(row["backend"], row["outcome"]) for row in db.execute(
                    "SELECT backend, outcome FROM inference_events ORDER BY id"
                )]
            self.assertEqual(request.call_args.args[0].full_url, "https://b.example/v1/chat/completions")
        self.assertEqual(response["output_text"], "GDC_OK")
        self.assertEqual(events, [("A", "pre_dispatch_route_controlled"), ("B", "success")])
        self.assertIsNone(BOT.route_control_state()["force_next_backend"])

    def test_route_control_rejects_unknown_or_unbounded_values(self):
        with self.assertRaisesRegex(ValueError, "unique A/B"):
            BOT.set_route_control({"disabled_backends": ["A", "A"], "force_next_backend": "A", "ttl_seconds": 60})
        with self.assertRaisesRegex(ValueError, "integer from 1"):
            BOT.set_route_control({"disabled_backends": [], "force_next_backend": None, "ttl_seconds": 301})

    def test_route_control_api_requires_internal_token_and_clears_state(self):
        server = BOT.ThreadingHTTPServer(("127.0.0.1", 0), BOT.ConversationAPIHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        base_url = f"http://127.0.0.1:{server.server_port}"
        try:
            with self.assertRaises(HTTPError) as unauthorized:
                urlopen(Request(f"{base_url}/v1/route-controls"), timeout=2)
            self.assertEqual(unauthorized.exception.code, 401)
            unauthorized.exception.close()
            body = json.dumps({
                "disabled_backends": ["A"], "force_next_backend": "A", "ttl_seconds": 60,
            }).encode()
            request = Request(
                f"{base_url}/v1/route-controls", data=body,
                headers={"Authorization": "Bearer test-internal-token", "Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(request, timeout=2) as response:
                controls = json.load(response)
            self.assertEqual(controls["disabled_backends"], ["A"])
            clear = Request(
                f"{base_url}/v1/route-controls/clear", data=b"{}",
                headers={"Authorization": "Bearer test-internal-token", "Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(clear, timeout=2) as response:
                cleared = json.load(response)
            self.assertEqual(cleared["disabled_backends"], [])
            self.assertIsNone(cleared["force_next_backend"])
        finally:
            server.shutdown()
            worker.join(timeout=2)
            server.server_close()

    def test_gateway_completion_does_not_fallback_after_ambiguous_dispatch(self):
        headers = Message()
        headers["X-GDC-Admission"] = "dispatched_once"
        error = HTTPError("https://a.example/v1/chat/completions", 503, "Unavailable", headers, None)
        BOT._backend_cursor = 0
        with BOT.connection() as db, patch.object(BOT, "GATEWAY_BACKENDS", self.ab_backends()), self.admission_ready(), patch.object(
            BOT, "urlopen", side_effect=error
        ) as request:
            with self.assertRaisesRegex(RuntimeError, "gateway returned HTTP 503"):
                BOT.gateway_completion(db, BOT.create_conversation(db, 51), "no retry")
        self.assertEqual(request.call_count, 1)
        self.assertEqual(request.call_args.args[0].full_url, "https://a.example/v1/chat/completions")

    def test_output_filter_removes_multiple_and_unclosed_think_blocks(self):
        self.assertEqual(
            BOT.visible_output_text("<THINK>first</THINK>Answer<think>second</think>"),
            "Answer",
        )
        self.assertEqual(BOT.visible_output_text("Answer\n<think>unfinished"), "Answer")

    def test_metrics_count_unique_users_and_premium_without_identifier_labels(self):
        with BOT.connection() as db:
            BOT.upsert_user(db, 1001, False)
            BOT.record_interaction(db, 1001, "message", "success", False)
            BOT.upsert_user(db, 2002, True)
            BOT.record_interaction(db, 2002, "command", "success", True)
            metrics = BOT.render_metrics(db)
        self.assertIn('gdc_telegram_bot_unique_users{premium="false"} 1', metrics)
        self.assertIn('gdc_telegram_bot_unique_users{premium="true"} 1', metrics)
        self.assertIn('premium="true"', metrics)
        self.assertNotIn("1001", metrics)
        self.assertNotIn("2002", metrics)

    def test_health_distinguishes_process_health_from_recent_inference(self):
        with BOT.connection() as db:
            self.assertEqual(BOT.health_payload(db)["status"], "ok")
            self.assertFalse(BOT.health_payload(db)["inference_ready"])
            BOT.record_inference(db, "success", {"prompt_tokens": 1, "completion_tokens": 1})
            health = BOT.health_payload(db)
        self.assertTrue(health["inference_ready"])
        self.assertIsInstance(health["last_success_timestamp"], int)

    def test_telegram_poll_timeout_exceeds_short_request_timeout(self):
        observed = []

        def fake_urlopen(_request, timeout):
            observed.append(timeout)
            return FakeResponse({"ok": True, "result": []})

        with patch.object(BOT, "urlopen", side_effect=fake_urlopen):
            BOT.telegram_request("sendChatAction", {"chat_id": 1, "action": "typing"})
            BOT.telegram_request("getUpdates", {"timeout": 30})
        self.assertEqual(observed, [BOT.TELEGRAM_REQUEST_TIMEOUT_SECONDS, BOT.TELEGRAM_POLL_TIMEOUT_SECONDS])
        self.assertGreater(BOT.TELEGRAM_POLL_TIMEOUT_SECONDS, 30)

    def test_probe_returns_the_direct_gateway_completion_shape(self):
        with BOT.connection() as db, patch.object(
            BOT, "gateway_completion", return_value={
                "status": "completed",
                "conversation": {"id": "conv_probe"},
                "output_text": "GDC_OK",
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
            }
        ):
            result = BOT.run_probe()
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["conversation_id_present"])
        self.assertTrue(result["output_present"])
        self.assertTrue(result["usage_present"])

    def test_handle_sends_user_message_through_selected_gateway(self):
        update = {
            "message": {
                "chat": {"id": 3003, "type": "private"},
                "from": {"id": 3003, "is_premium": True},
                "text": "What is Gonka?",
            }
        }
        replies = []
        typing = []
        with BOT.connection() as db, patch.object(
            BOT, "gateway_completion", return_value={"output_text": "A network."}
        ), patch.object(
            BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)
        ), patch.object(BOT, "send_typing", side_effect=lambda chat_id: typing.append(chat_id)):
            BOT.handle(db, update)
            self.assertEqual(db.execute("SELECT count(*) FROM users").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT outcome FROM interactions").fetchone()[0], "success")
        self.assertEqual(replies, ["A network."])
        self.assertEqual(typing, [3003])

    def test_handle_replies_promptly_when_inference_fails(self):
        update = {
            "message": {
                "chat": {"id": 4004, "type": "private"},
                "from": {"id": 4004},
                "text": "hello",
            }
        }
        replies = []
        typing = []
        with BOT.connection() as db, patch.object(
            BOT, "gateway_completion", side_effect=RuntimeError("unavailable")
        ), patch.object(BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)), patch.object(
            BOT, "send_typing", side_effect=lambda chat_id: typing.append(chat_id)
        ):
            BOT.handle(db, update)
            outcome = db.execute("SELECT outcome FROM interactions").fetchone()["outcome"]
        self.assertEqual(typing, [4004])
        self.assertEqual(replies, ["Inference is temporarily unavailable, please try again later."])
        self.assertEqual(outcome, "error")

    def test_handle_types_then_dispatches_one_gateway_completion(self):
        update = {
            "message": {
                "chat": {"id": 4006, "type": "private"},
                "from": {"id": 4006},
                "text": "hello",
            }
        }
        calls = []

        with BOT.connection() as db, patch.object(
            BOT, "telegram_request", side_effect=lambda method, _payload: calls.append(f"telegram:{method}")
        ), patch.object(
            BOT, "gateway_completion", side_effect=lambda *_args: calls.append("gateway-completion") or {"output_text": "ready"}
        ), patch.object(
            BOT, "conversation_for_user", return_value="conv_order"
        ):
            BOT.handle(db, update)

        self.assertEqual(calls, [
            "telegram:sendChatAction",
            "gateway-completion",
            "telegram:sendMessage",
        ])

    def test_admission_probe_default_is_short(self):
        self.assertEqual(BOT.GATEWAY_ADMISSION_TIMEOUT_SECONDS, 3)

    def test_handle_gateway_unavailable_replies_without_duplicate_dispatch(self):
        update = {
            "message": {
                "chat": {"id": 4007, "type": "private"},
                "from": {"id": 4007},
                "text": "hello",
            }
        }
        calls = []
        replies = []

        def reject_gateway(*_args):
            calls.append("gateway-completion")
            raise RuntimeError("unavailable")

        with BOT.connection() as db, patch.object(
            BOT, "telegram_request", side_effect=lambda method, _payload: calls.append(f"telegram:{method}")
        ), patch.object(
            BOT, "gateway_completion", side_effect=reject_gateway
        ), patch.object(
            BOT, "conversation_for_user", return_value="conv_unavailable"
        ), patch.object(BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)):
            BOT.handle(db, update)
            outcome = db.execute("SELECT outcome FROM interactions").fetchone()["outcome"]

        self.assertEqual(calls, ["telegram:sendChatAction", "gateway-completion"])
        self.assertEqual(replies, ["Inference is temporarily unavailable, please try again later."])
        self.assertEqual(outcome, "error")

    def test_gateway_completion_stops_before_dispatch_when_admission_is_unavailable(self):
        with BOT.connection() as db:
            conversation = BOT.create_conversation(db, 4005)
            with patch.object(BOT, "urlopen", return_value=FakeResponse({
                "state": "UNAVAILABLE", "available": False, "reason": "runtime_unavailable",
            })) as request:
                with self.assertRaisesRegex(RuntimeError, "gateway pre dispatch rejected"):
                    BOT.gateway_completion(db, conversation, "hello")
            self.assertEqual(request.call_count, 1)
            outcome = db.execute(
                "SELECT outcome FROM inference_events ORDER BY id DESC LIMIT 1"
            ).fetchone()["outcome"]
        self.assertEqual(outcome, "pre_dispatch_runtime_unavailable")

    def test_handle_replies_to_non_text_private_messages(self):
        update = {
            "message": {
                "chat": {"id": 5005, "type": "private"},
                "from": {"id": 5005},
                "sticker": {"file_id": "ignored"},
            }
        }
        replies = []
        with BOT.connection() as db, patch.object(
            BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)
        ):
            BOT.handle(db, update)
            outcome = db.execute("SELECT outcome FROM interactions").fetchone()["outcome"]
        self.assertEqual(replies, ["Please send a text message to run inference."])
        self.assertEqual(outcome, "rejected")

    def test_faucet_validates_address_and_persists_one_intent_per_update(self):
        address = "gonka1mrm3xar9w858cd0dk697v9fdzuleey9a3lx2kl"
        update = {
            "update_id": 901,
            "message": {"chat": {"id": 6001, "type": "private"}, "from": {"id": 6001}, "text": f"/faucet {address}"},
        }
        replies, requests = [], []

        def faucet_request(requested_address, telegram_id, key):
            requests.append((requested_address, telegram_id, key))
            return 202, {"state": "submitted", "amount_ngonka": "100", "txhash": "A" * 64, "confirmation": "pending"}

        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _chat, text: replies.append(text)), patch.object(BOT, "faucet_request", side_effect=faucet_request):
            BOT.handle(db, update)
            BOT.handle(db, update)
            row = db.execute("SELECT address, state, txhash FROM faucet_updates WHERE update_id = 901").fetchone()

        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0][2], requests[1][2])
        self.assertEqual((row["address"], row["state"], row["txhash"]), (address, "submitted", "A" * 64))
        self.assertIn("chain confirmation is still pending", replies[0])

    def test_faucet_invalid_address_never_calls_service(self):
        update = {
            "update_id": 902,
            "message": {"chat": {"id": 6002, "type": "private"}, "from": {"id": 6002}, "text": "/faucet gonka1notachecksum"},
        }
        replies = []
        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _chat, text: replies.append(text)), patch.object(BOT, "faucet_request") as faucet:
            BOT.handle(db, update)
        faucet.assert_not_called()
        self.assertEqual(replies, ["Usage: /faucet <valid Gonka address>"])

    def test_faucet_administration_forwards_control_to_service(self):
        update = {
            "update_id": 903,
            "message": {"chat": {"id": 6003, "type": "private"}, "from": {"id": 6003}, "text": "/faucet open"},
        }
        replies = []
        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _chat, text: replies.append(text)), patch.object(
            BOT, "faucet_admin_request", return_value=(200, {"state": "open"})
        ) as faucet_admin:
            BOT.handle(db, update)
        faucet_admin.assert_called_once_with("open", 6003)
        self.assertEqual(replies, ["Faucet is open."])

    def test_api_key_aliases_use_update_bound_broker_and_never_inference(self):
        replies = []
        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _chat, text: replies.append(text)), patch.object(
            BOT, "key_broker_request", return_value=(200, "sk-gdc-test-key")
        ) as broker, patch.object(BOT, "gateway_completion") as inference:
            for update_id, command in ((904, "/api_key"), (905, "/api-key")):
                BOT.handle(db, {"update_id": update_id, "message": {"chat": {"id": 6004, "type": "private"}, "from": {"id": 6004}, "text": command}})
        self.assertEqual(broker.call_args_list, [call(6004, 904), call(6004, 905)])
        inference.assert_not_called()
        self.assertTrue(all("sk-gdc-test-key" in reply for reply in replies))

    def test_api_key_rejects_forwarded_message(self):
        replies = []
        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _chat, text: replies.append(text)), patch.object(BOT, "key_broker_request") as broker:
            BOT.handle(db, {"update_id": 906, "message": {"chat": {"id": 6005, "type": "private"}, "from": {"id": 6005}, "text": "/api_key", "forward_origin": {}}})
        broker.assert_not_called()
        self.assertEqual(replies, ["API keys can only be requested in a new private message."])

    def test_faucet_controls_use_actual_sender_never_chat_id_or_inference(self):
        with BOT.connection() as db, patch.object(BOT, "send_message"), patch.object(BOT, "gateway_completion") as inference, patch.object(
            BOT, "faucet_admin_request", return_value=(200, {"state": "closed", "limit_ngonka": "100000000000", "administrator_ids": [77]})
        ) as admin:
            for text in ("/faucet add 88", "/faucet remove 88", "/faucet list", "/faucet limit 100.000000001"):
                BOT.handle(db, {"message": {"chat": {"id": 999, "type": "private"}, "from": {"id": 77}, "text": text}})
        self.assertEqual(admin.call_args_list, [call("add", 77, 88), call("remove", 77, 88), call("list", 77), call("limit", 77, 100000000001)])
        inference.assert_not_called()

    def test_faucet_control_parser_rejects_ambiguous_or_unbounded_amounts(self):
        for text in ("/faucet limit -1", "/faucet limit 1e2", "/faucet limit 01", "/faucet limit 0.0000000001", "/faucet limit 9223372037", "/faucet add true", "/faucet remove 0", "/faucet open extra"):
            with self.assertRaises(ValueError):
                BOT.faucet_control(text.split())
        with self.assertRaises(ValueError):
            BOT.faucet_control("/faucet limit 0".split())
        self.assertEqual(BOT.faucet_control("/faucet limit 100 24h".split()), ("limit", 100000000000))

    def test_faucet_control_invalid_input_does_not_leave_bot(self):
        with BOT.connection() as db, patch.object(BOT, "send_message"), patch.object(BOT, "faucet_admin_request") as admin, patch.object(BOT, "gateway_completion") as inference:
            BOT.handle(db, {"message": {"chat": {"id": 77, "type": "private"}, "from": {"id": 77}, "text": "/faucet limit 1e9"}})
        admin.assert_not_called()
        inference.assert_not_called()

    def test_faucet_forwards_groups_and_boolean_identity_cannot_control_service(self):
        with BOT.connection() as db, patch.object(BOT, "send_message"), patch.object(BOT, "faucet_admin_request") as admin, patch.object(BOT, "faucet_request") as funding:
            for field in ("forward_origin", "forward_from", "forward_from_chat", "forward_sender_name", "forward_date"):
                BOT.handle(db, {"message": {"chat": {"id": 77, "type": "private"}, "from": {"id": 77}, "text": "/faucet open", field: {}}})
            for kind, actor in (("group", 77), ("private", True), ("private", "77")):
                BOT.handle(db, {"message": {"chat": {"id": 77, "type": kind}, "from": {"id": actor}, "text": "/faucet open"}})
        admin.assert_not_called()
        funding.assert_not_called()

    def test_faucet_admin_request_separate_capability_exact_integer_payload(self):
        with patch.object(BOT, "FAUCET_URL", "http://127.0.0.1:1/v1/telegram-claim"), patch.object(BOT, "FAUCET_TOKEN", "private-fixture"), patch.object(BOT, "urlopen", return_value=FakeResponse({"state": "closed"})) as request:
            BOT.faucet_admin_request("limit", 77, 100000000001)
        sent = request.call_args.args[0]
        self.assertEqual(sent.full_url, "http://127.0.0.1:1/v1/telegram-admin")
        self.assertEqual(sent.get_header("Authorization"), "Bearer private-fixture")
        self.assertEqual(json.loads(sent.data), {"telegram_user_id": 77, "action": "limit", "limit_ngonka": 100000000001})

    def test_faucet_reports_distinct_closure_quota_and_unknown_amount(self):
        self.assertIn("closed", BOT.faucet_reply({"error": "telegram faucet is closed"}))
        self.assertIn("rolling 24-hour", BOT.faucet_reply({"error": "telegram faucet rolling amount limit reached", "state": "rate_limited"}))
        self.assertIn("unknown", BOT.faucet_reply({"error": "telegram faucet legacy amount requires reconciliation or window expiry"}))
        self.assertIn("will not be rebroadcast", BOT.faucet_reply({"state": "pending"}))
        self.assertIn("failed", BOT.faucet_reply({"state": "failed"}))

    def test_admins_alias_and_user_status_stay_outside_model_prompts(self):
        replies = []
        with BOT.connection() as db, patch.object(BOT, "send_message", side_effect=lambda _, text: replies.append(text)), patch.object(BOT, "gateway_completion") as inference, patch.object(
            BOT, "faucet_admin_request", return_value=(200, {"state": "open", "remaining_ngonka": "100000000000", "chain_service_state": "unverified", "accounting": "known", "administrator_ids": [77]})
        ) as admin:
            for text in ("/admins list", "/admins add 88", "/admins remove 88", "/faucet status"):
                BOT.handle(db, {"message": {"chat": {"id": 44, "type": "private"}, "from": {"id": 44}, "text": text}})
        self.assertEqual(admin.call_args_list, [call("list", 44), call("add", 44, 88), call("remove", 44, 88), call("status", 44)])
        self.assertIn("Remaining rolling 24-hour allowance", replies[-1])
        self.assertIn("unverified", replies[-1])
        inference.assert_not_called()

    def test_local_inference_without_telegram_is_not_delivery_proof(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            BOT.record_inference(db, "success", backend="A")
            self.assertTrue(BOT.health_payload(db)["inference_ready"])
            self.assertEqual(BOT.delivery_observation(db)["state"], "UNVERIFIED")
            self.assertNotIn('outcome="delivered"', BOT.render_metrics(db))

    def test_delivery_binds_actual_fallback_receipt_and_does_not_count_a_twice(self):
        def admission(_db, backend, *_args):
            if backend["name"] == "A":
                raise BOT.GatewayPreDispatchRejected("temporary")
        payload = {"choices": [{"message": {"content": "visible answer"}}]}
        update = {"message": {"chat": {"id": 3003, "type": "private"}, "from": {"id": 3003}, "text": "hello"}}
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000), patch.object(BOT, "GATEWAY_BACKENDS", self.ab_backends()), patch.object(
            BOT, "require_gateway_admission", side_effect=admission
        ), patch.object(BOT, "urlopen", return_value=FakeResponse(payload)), patch.object(BOT, "send_typing"), patch.object(BOT, "send_message"):
            BOT.handle(db, update)
            observation = BOT.delivery_observation(db)
            self.assertEqual((observation["state"], observation["backend"], observation["model"]), ("RECENT", "B", BOT.MODEL))
            self.assertEqual(observation["combined_readiness"], "UNVERIFIED")
            rows = db.execute("SELECT backend, delivery_state FROM inference_events WHERE outcome='success'").fetchall()
            self.assertEqual([(row[0], row[1]) for row in rows], [("B", "delivered")])
            metrics = BOT.render_metrics(db)
            self.assertIn(f'gdc_telegram_bot_inference_deliveries_total{{backend="B",model="{BOT.MODEL}",outcome="delivered"}} 1', metrics)
            self.assertNotIn('telegram_id=', metrics)
            self.assertNotIn('inference_event_id=', metrics)
            self.assertNotIn("visible answer", metrics)

    def test_delivery_failure_does_not_invent_inference_failure_or_positive_delivery(self):
        payload = {"choices": [{"message": {"content": "visible answer"}}]}
        update = {"message": {"chat": {"id": 3003, "type": "private"}, "from": {"id": 3003}, "text": "hello"}}
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000), self.admission_ready(), patch.object(
            BOT, "urlopen", return_value=FakeResponse(payload)
        ), patch.object(BOT, "send_typing"), patch.object(BOT, "send_message", side_effect=OSError("Telegram unavailable")):
            BOT.handle(db, update)
            self.assertEqual(BOT.delivery_observation(db)["state"], "DELIVERY_FAILED")
            self.assertTrue(BOT.health_payload(db)["inference_ready"])
            self.assertNotIn('outcome="delivered"', BOT.render_metrics(db))

    def test_delivery_expiry_and_reads_never_renew_event_timestamp(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            event = BOT.record_inference(db, "success", backend="B")
            BOT.record_delivery(db, event, True)
        for current, state in ((1120, "RECENT"), (1121, "STALE"), (999, "UNVERIFIED")):
            with BOT.connection() as db, patch.object(BOT, "now", return_value=current):
                observation = BOT.health_payload(db)["delivery_observation"]
                self.assertEqual(observation["state"], state)
                self.assertEqual(observation["observed_at"], 1000)
                self.assertEqual(observation["expires_at"], 1120)
                self.assertIn(f'gdc_telegram_bot_last_delivery_timestamp_seconds{{backend="B",model="{BOT.MODEL}"}} 1000', BOT.render_metrics(db))

    def test_delivery_duplicate_or_wrong_receipt_cannot_rebind_or_refresh(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            delivered = BOT.record_inference(db, "success", backend="A")
            other = BOT.record_inference(db, "success", backend="B")
            failed = BOT.record_inference(db, "http_400", backend="A")
            for wrong in (None, True, "1", -1, failed, 99999):
                BOT.record_delivery(db, wrong, True)
            BOT.record_delivery(db, delivered, True)
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1050):
            BOT.record_delivery(db, delivered, False)
            observation = BOT.delivery_observation(db)
            self.assertEqual((observation["observed_at"], observation["state"], observation["backend"]), (1000, "RECENT", "A"))
            self.assertEqual(db.execute("SELECT delivery_state FROM inference_events WHERE id=?", (other,)).fetchone()[0], "unverified")

    def test_same_second_delivery_order_is_not_completion_order(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            first = BOT.record_inference(db, "success", backend="A")
            second = BOT.record_inference(db, "success", backend="B")
            BOT.record_delivery(db, second, True)
            BOT.record_delivery(db, first, False)
            self.assertEqual(BOT.delivery_observation(db)["state"], "DELIVERY_FAILED")
            self.assertEqual(BOT.delivery_observation(db)["backend"], "A")

    def test_clock_rollback_and_restart_cannot_hide_newer_delivery_failure(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            first = BOT.record_inference(db, "success", backend="A")
            BOT.record_delivery(db, first, True)
        with BOT.connection() as db, patch.object(BOT, "now", return_value=999):
            second = BOT.record_inference(db, "success", backend="B")
            BOT.record_delivery(db, second, False)
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1001):
            observation = BOT.delivery_observation(db)
            self.assertEqual(observation["state"], "DELIVERY_FAILED")
            self.assertEqual((observation["backend"], observation["observed_at"]), ("B", 999))

    def test_delivery_timestamp_metric_uses_actual_last_event_not_max_wall_clock(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            first = BOT.record_inference(db, "success", backend="B")
            BOT.record_delivery(db, first, True)
        with BOT.connection() as db, patch.object(BOT, "now", return_value=999):
            second = BOT.record_inference(db, "success", backend="B")
            BOT.record_delivery(db, second, True)
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1001):
            self.assertEqual(BOT.delivery_observation(db)["observed_at"], 999)
            metric = f'gdc_telegram_bot_last_delivery_timestamp_seconds{{backend="B",model="{BOT.MODEL}"}}'
            self.assertIn(metric + " 999\n", BOT.render_metrics(db))
            self.assertNotIn(metric + " 1000\n", BOT.render_metrics(db))

    def test_unfinished_delivery_after_restart_is_not_positive(self):
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000):
            event = BOT.record_inference(db, "success", backend="A")
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1001):
            self.assertEqual(BOT.delivery_observation(db)["state"], "UNVERIFIED")
            self.assertEqual(db.execute("SELECT delivery_state FROM inference_events WHERE id=?", (event,)).fetchone()[0], "unverified")

    def test_older_success_rows_migrate_without_inventing_delivery(self):
        with sqlite3.connect(BOT.DB_FILE) as db:
            db.execute("CREATE TABLE inference_events (id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, "
                       "outcome TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, "
                       "total_tokens INTEGER NOT NULL DEFAULT 0, usage_missing INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, "
                       "backend TEXT NOT NULL DEFAULT 'unknown')")
            db.execute("INSERT INTO inference_events(model,outcome,created_at,backend) VALUES (?,?,?,?)", (BOT.MODEL, "success", 1000, "B"))
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1001):
            self.assertTrue(BOT.health_payload(db)["inference_ready"])
            self.assertEqual(BOT.delivery_observation(db)["state"], "UNVERIFIED")
            self.assertNotIn('outcome="delivered"', BOT.render_metrics(db))

    def test_partial_telegram_chunk_delivery_is_failure_not_completed_reply(self):
        parts = []
        def telegram(method, payload):
            self.assertEqual(method, "sendMessage")
            parts.append(payload["text"])
            if len(parts) == 2:
                raise OSError("second chunk unavailable")
        payload = {"choices": [{"message": {"content": "a" * 8100}}]}
        update = {"message": {"chat": {"id": 3003, "type": "private"}, "from": {"id": 3003}, "text": "hello"}}
        with BOT.connection() as db, patch.object(BOT, "now", return_value=1000), self.admission_ready(), patch.object(
            BOT, "urlopen", return_value=FakeResponse(payload)
        ), patch.object(BOT, "send_typing"), patch.object(BOT, "telegram_request", side_effect=telegram):
            BOT.handle(db, update)
            self.assertEqual(BOT.delivery_observation(db)["state"], "DELIVERY_FAILED")
            self.assertEqual(len(parts), 2)
            self.assertNotIn('outcome="delivered"', BOT.render_metrics(db))


if __name__ == "__main__":
    unittest.main()
