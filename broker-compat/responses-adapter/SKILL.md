---
name: openai-responses-adapter
description: >-
  OpenAI Responses adapter for Gonka broker HTTP proxies: POST /v1/responses
  translates to chat-completions, then host-compat shims, then the same
  gateway. Developed by Dahl (https://inference.dahl.global) together with
  Gonka External TestLab (https://github.com/paranjko/external-test-lab).
---

# OpenAI Responses adapter

Developed by [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

**Where it lives:** the broker OpenAI HTTP proxy, **same process** as
`POST /v1/chat/completions`, **before** the inference gateway.

CompatCanary `--profile modern` is how the gap usually shows (405 on
`/v1/responses`). Codex CLI and Agents SDK (`client.responses.create()`)
hard-call this path. Chat Completions stays for Cursor / chat-mode Cline /
most SDKs.

```
Codex / Agents SDK
    → POST /v1/responses
    → ToChat
    → host-compat shims (chat body)
    → gateway → host
    → FromChat / SSE translator
```

**Port:** spec, not a library. Same process as `POST /v1/chat/completions`.
After ToChat, run a host-compat layer on that chat body (this catalog
[`broker-compat/host-compat/`](../host-compat/) or the equivalent already on
the proxy).
Do not flatten Responses `input` inside host-compat. Any language.
Do not start a new process.

**Before coding:** read [reference.md](reference.md) (SSE order).
**Done when:** the probes below pass: `object=response`, stream has
`response.created` + `response.completed` and no `[DONE]`,
`previous_response_id` → 400, `/v1/chat/completions` still works.

Toggle with one env flag (e.g. `RESPONSES_ADAPTER=true`, default on). When
off, `POST /v1/responses` must return **404 JSON**, not a bare mux 405 / HTML
landing.

Log one line per request: stream flag, tool count, model (no prompts, no keys).

Do not flatten Responses `input` items or strip Responses-only keys inside
host-compat — `ToChat` must already emit a chat-only body.

## Shipped catalog

| Piece | Behavior |
|-------|----------|
| `POST /v1/responses` | JSON (`stream: false`) or Responses SSE (`stream: true`) |
| `ToChat` | `input` / `instructions` / flat function tools / `max_output_tokens` → chat |
| `FromChat` | `object: "response"`, `output[]`, `output_text`, remapped `usage` |
| SSE | `response.created` (full object) … `response.completed`. **No** `data: [DONE]` |
| Hosted tools in `tools[]` | Skip. Empty after skip → continue **without** tools (do not 400) |
| `store` / `include` / `truncation` / `metadata` / … | Strip, do not 400 |
| `GET/DELETE /v1/responses/{id}` | 404 JSON: not stored |
| `POST /v1/responses/compact` | 404 JSON: not supported (Codex must use a **custom** provider id) |

## Do not

- Pretend store works (`previous_response_id` → **400**, not silent ignore)
- Implement `/v1/responses/compact` or Conversations API
- Clone hosted OpenAI tools (web search, computer use, their code interpreter)
- Fake `encrypted_content`
- Extra shims “so CompatCanary is 100”
- Coerce `tool_choice: required` → `auto`
- Emit `response.created` before first upstream byte (breaks first-token retry)
- Document the Codex provider as built-in `openai` / `Azure`

## 400 vs strip

| Condition | Action |
|-----------|--------|
| `previous_response_id` or `conversation` set | **400** — send full `input` every turn |
| `background: true` | **400** |
| `item_reference` in `input` | **400** (needs store) |
| `tool_choice` type is a hosted tool | **400** |
| `store: true` | **Strip** |
| Hosted types inside `tools[]` | **Skip**; if none left, no `tools` key |

## Codex

Custom provider id, **not** `openai`. `model` is whatever your proxy serves:

```toml
model = "MiniMaxAI/MiniMax-M2.7"
model_provider = "your-broker"

[model_providers.your-broker]
name = "Your broker"
base_url = "https://your-broker.example/v1"
env_key = "YOUR_API_KEY"
requires_openai_auth = false
```

Omit `wire_api` or use responses. `wire_api = "chat"` is a Codex hard error.

Function tools: yes. OpenAI hosted `web_search`: no. Long context: Codex
compacts **locally** when the provider id is not `openai`.

## Probe (your keys)

1. `POST /v1/responses` with `model` + `input` string → `object=response`.
2. `"stream": true` → `response.created` + `response.completed`, no `[DONE]`.
3. `previous_response_id` set → 400.
4. `POST /v1/responses/compact` → 404 JSON.
5. `POST /v1/chat/completions` still works.

See [reference.md](reference.md) for field maps, SSE order, and error codes.

## Related

Host-compat shims (chat-body rewrites): `broker-compat/host-compat/`.
