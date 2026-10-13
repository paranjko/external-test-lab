#!/usr/bin/env python3
"""Register/read back the private key menu using the container's capability."""
import json
import os
from urllib.error import URLError
from urllib.request import Request, urlopen

COMMANDS = [{"command": "api_key", "description": "Issue or replace stable API key"}]
SCOPE = {"type": "all_private_chats"}


def register_commands(token, open_request=urlopen):
    if not isinstance(token, str) or not token or any(char.isspace() for char in token):
        raise ValueError("invalid BotFather capability")

    def call(method, payload=None):
        request = Request("https://api.telegram.org/bot" + token + "/" + method,
                          data=json.dumps(payload or {}).encode(),
                          headers={"Content-Type": "application/json"}, method="POST")
        with open_request(request, timeout=15) as response:
            body = json.load(response)
        if not isinstance(body, dict) or body.get("ok") is not True:
            raise ValueError("Telegram rejected management request")
        return body.get("result")

    identity = call("getMe")
    if not isinstance(identity, dict) or identity.get("is_bot") is not True:
        raise ValueError("Telegram identity readback differs")
    call("deleteMyCommands")
    call("setMyCommands", {"scope": SCOPE, "commands": COMMANDS})
    if call("getMyCommands", {"scope": SCOPE}) != COMMANDS:
        raise ValueError("Telegram private commands readback differs")
    if call("getMyCommands") != []:
        raise ValueError("Telegram default commands were not cleared")


if __name__ == "__main__":
    try:
        register_commands(os.environ.get("TELEGRAM_BOT_TOKEN"))
    except (ValueError, OSError, URLError):
        raise SystemExit("Telegram command registration failed; inspect private bot configuration")
