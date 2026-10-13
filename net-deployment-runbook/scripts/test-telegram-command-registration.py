#!/usr/bin/env python3
"""Offline Telegram management contract: no real API calls or credentials."""
import importlib.util
import io
import json
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parent / "telegram-bot/register-commands.py"
spec = importlib.util.spec_from_file_location("registration", PATH)
registration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registration)


class Registration(unittest.TestCase):
    def fixture(self, failure=None):
        calls = []
        def open_request(request, timeout):
            method = request.full_url.rsplit("/", 1)[-1]
            payload = json.loads(request.data)
            calls.append((method, payload))
            self.assertEqual(request.full_url, "https://api.telegram.org/botfixture-token/" + method)
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(timeout, 15)
            result = {"getMe": {"is_bot": True}, "deleteMyCommands": True, "setMyCommands": True,
                      "getMyCommands": registration.COMMANDS if payload.get("scope") else []}[method]
            if method == failure:
                result = None
            return io.BytesIO(json.dumps({"ok": method != failure, "result": result}).encode())
        return calls, open_request

    def test_registration_and_exact_private_default_readback(self):
        calls, opener = self.fixture()
        registration.register_commands("fixture-token", opener)
        self.assertEqual([method for method, _ in calls], ["getMe", "deleteMyCommands", "setMyCommands", "getMyCommands", "getMyCommands"])
        self.assertEqual(calls[2][1], {"scope": {"type": "all_private_chats"}, "commands": registration.COMMANDS})
        self.assertEqual(calls[-1][1], {})

    def test_missing_capability_is_rejected_before_dispatch(self):
        for token in (None, "", "white space"):
            calls, opener = self.fixture()
            with self.assertRaises(ValueError):
                registration.register_commands(token, opener)
            self.assertEqual(calls, [])

    def test_failure_stops_remaining_management_writes(self):
        for method in ("getMe", "deleteMyCommands", "setMyCommands", "getMyCommands"):
            calls, opener = self.fixture(method)
            with self.assertRaises(ValueError):
                registration.register_commands("fixture-token", opener)
            self.assertEqual(calls[-1][0], method)

    def test_changed_readback_does_not_claim_success(self):
        calls, original = self.fixture()
        def opener(request, timeout):
            response = original(request, timeout)
            if request.full_url.endswith("/getMyCommands"):
                return io.BytesIO(b'{"ok":true,"result":[{"command":"foreign"}]}')
            return response
        with self.assertRaises(ValueError):
            registration.register_commands("fixture-token", opener)


if __name__ == "__main__":
    unittest.main(verbosity=2)
