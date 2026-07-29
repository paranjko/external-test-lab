#!/usr/bin/env python3
"""
chat.py — interactive streaming chat client for gonka ML nodes (vLLM API).

Usage:
    chat.py "what is a black hole?"     # ask one question, then continue
    chat.py                             # interactive from the start

Inside the session:
    /exit, /quit, Ctrl-D     — quit
    /reset                   — clear conversation history (start fresh)
    /reasoning               — toggle showing reasoning blocks (default: hidden)
"""
import sys
import json
import argparse
import urllib.request
import urllib.error

ENDPOINT = "http://localhost:5050/v1/chat/completions"
MODEL = "MiniMaxAI/MiniMax-M2.7"
MAX_TOKENS = 4096

history = []
show_reasoning = False


def stream_response(messages):
    payload = json.dumps({
        "model": MODEL,
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "stream": True,
    }).encode()

    req = urllib.request.Request(
        ENDPOINT,
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    full_content = ""
    in_reasoning = False
    reasoning_label_shown = False

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue

                delta = chunk.get("choices", [{}])[0].get("delta", {})

                if "reasoning" in delta and delta["reasoning"]:
                    if show_reasoning:
                        if not reasoning_label_shown:
                            print("\n\033[2m[thinking] ", end="", flush=True)
                            reasoning_label_shown = True
                        print(delta["reasoning"], end="", flush=True)
                    in_reasoning = True

                if "content" in delta and delta["content"]:
                    if in_reasoning and show_reasoning:
                        print("\033[0m\n", end="", flush=True)
                    in_reasoning = False
                    print(delta["content"], end="", flush=True)
                    full_content += delta["content"]

    except urllib.error.URLError as e:
        print(f"\n[error] connection failed: {e}", file=sys.stderr)
        return None
    except KeyboardInterrupt:
        print("\n[interrupted]", file=sys.stderr)
        return None

    if show_reasoning and reasoning_label_shown and not full_content:
        print("\033[0m", end="", flush=True)

    print()
    return full_content


def chat_once(question):
    history.append({"role": "user", "content": question})
    reply = stream_response(history)
    if reply:
        history.append({"role": "assistant", "content": reply})


def main():
    global ENDPOINT, MODEL, show_reasoning

    parser = argparse.ArgumentParser(
        description="Interactive streaming chat client for gonka ML nodes",
    )
    parser.add_argument("question", nargs="*",
        help="initial question (optional)")
    parser.add_argument("--endpoint", default=ENDPOINT,
        help=f"vLLM endpoint (default: {ENDPOINT})")
    parser.add_argument("--model", default=MODEL,
        help=f"model id (default: {MODEL})")
    parser.add_argument("--reasoning", action="store_true",
        help="show reasoning blocks from the start")
    args = parser.parse_args()

    ENDPOINT = args.endpoint
    MODEL = args.model
    show_reasoning = args.reasoning

    print(f"\033[2m# Connected to {ENDPOINT} | model: {MODEL}")
    print(f"# /exit to quit, /reset to clear history, /reasoning to toggle thinking\033[0m\n")

    if args.question:
        initial = " ".join(args.question)
        print(f"\033[1m> {initial}\033[0m")
        chat_once(initial)
        print()

    while True:
        try:
            question = input("\033[1m> \033[0m").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not question:
            continue
        if question in ("/exit", "/quit"):
            break
        if question == "/reset":
            history.clear()
            print("\033[2m# history cleared\033[0m\n")
            continue
        if question == "/reasoning":
            show_reasoning = not show_reasoning
            state = "on" if show_reasoning else "off"
            print(f"\033[2m# reasoning display: {state}\033[0m\n")
            continue

        chat_once(question)
        print()


if __name__ == "__main__":
    main()

