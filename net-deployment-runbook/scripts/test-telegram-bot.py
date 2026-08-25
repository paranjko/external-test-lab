#!/usr/bin/env python3

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import URLError


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


class TelegramConsumerTest(unittest.TestCase):
    def setUp(self):
        if BOT.DB_FILE.exists():
            BOT.DB_FILE.unlink()
        if BOT.METRICS_FILE.exists():
            BOT.METRICS_FILE.unlink()

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
            with patch.object(BOT, "urlopen", return_value=FakeResponse(payload)):
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
            with patch.object(BOT, "urlopen", return_value=FakeResponse(payload)):
                response = BOT.gateway_completion(db, conversation, "hello")
            assistant = db.execute(
                "SELECT content FROM messages WHERE conversation_id = ? AND role = 'assistant'",
                (conversation,),
            ).fetchone()["content"]
        self.assertEqual(response["output_text"], "The visible answer")
        self.assertEqual(assistant, "The visible answer")
        self.assertNotIn("private reasoning", response["output_text"])

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

    def test_handle_sends_user_message_through_conversation_api(self):
        update = {
            "message": {
                "chat": {"id": 3003, "type": "private"},
                "from": {"id": 3003, "is_premium": True},
                "text": "What is Gonka?",
            }
        }
        requests = []

        def fake_internal(path, payload):
            requests.append((path, payload))
            if path == "/v1/conversations":
                return {"id": "conv_test"}
            return {"output_text": "A network."}

        replies = []
        typing = []
        with BOT.connection() as db, patch.object(BOT, "internal_api_request", side_effect=fake_internal), patch.object(
            BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)
        ), patch.object(BOT, "send_typing", side_effect=lambda chat_id: typing.append(chat_id)):
            BOT.handle(db, update)
            self.assertEqual(db.execute("SELECT count(*) FROM users").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT outcome FROM interactions").fetchone()[0], "success")
        self.assertEqual(requests[0], ("/v1/conversations", {"telegram_user_id": 3003}))
        self.assertEqual(requests[1], ("/v1/responses", {"conversation": "conv_test", "input": "What is Gonka?"}))
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
            BOT, "internal_api_request", side_effect=URLError("unavailable")
        ), patch.object(BOT, "send_message", side_effect=lambda _chat_id, text: replies.append(text)), patch.object(
            BOT, "send_typing", side_effect=lambda chat_id: typing.append(chat_id)
        ):
            BOT.handle(db, update)
            outcome = db.execute("SELECT outcome FROM interactions").fetchone()["outcome"]
        self.assertEqual(typing, [4004])
        self.assertEqual(replies, ["Inference is temporarily unavailable, please try again later."])
        self.assertEqual(outcome, "error")

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


if __name__ == "__main__":
    unittest.main()
