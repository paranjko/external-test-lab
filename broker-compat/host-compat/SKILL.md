---
name: openai-host-compat
description: >-
  OpenAI host-compat shims for Gonka broker HTTP proxies: rewrite agent
  chat-completions (Cursor, Cline, Zod, MCP) so stricter MiniMax/Kimi/DeepSeek
  hosts do not 400. Developed by Dahl (https://inference.dahl.global) together
  with Gonka External TestLab (https://github.com/paranjko/external-test-lab).
---

# OpenAI host-compat shims

Developed by [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

**Where it lives:** the broker OpenAI HTTP proxy (`POST /v1/chat/completions`),
**before** the inference gateway.

```
Agent → broker proxy (shims) → gateway → host validator → model
```

Log one line per rewrite: which shim fired (no prompts, no API keys).

Toggle with one env flag (e.g. `HOST_COMPAT_SHIMS=true`, default on) so a bad
rewrite can be disabled without a code rollback.

## Shipped shims (catalog)

Apply **in this order**. Each step is idempotent (second pass must not mint a
new id or flatten twice).

| Log name | Rewrite |
|----------|---------|
| `unwrap_extra_body` | Lift `extra_body` / `extraBody` keys onto the top level if absent; delete the envelope |
| `drop_unknown_knobs` | Drop SDK/host-unknown knobs (see list). **Keep** `thinking`, `chat_template_kwargs`, `reasoning_details` |
| `drop_null_parallel_tool_calls` | Delete `parallel_tool_calls` when it is `null` (leave `true`/`false`) |
| `max_completion_tokens` | Copy to `max_tokens` if missing; delete `max_completion_tokens` (never send both) |
| `reasoning_effort` | `max` / `maximum` / `extreme` / `highest` → `high` |
| `legacy_functions` | `functions` → `tools` when `tools` absent; `function_call` → `tool_choice` |
| `developer_role` | `role: "developer"` → `"system"` |
| `flatten_content` | `{type:"text",text}` arrays → one string. Skip MiniMax `{name,type,text}` tool results and vision (`image_url`, …) |
| `blank_tool_content` | Non-empty `tool_calls` + `content: ""` → `content: null` |
| `empty_content_array` | Non-empty `tool_calls` + `content: []` → `null` |
| `fill_blank_user_system` | Empty/whitespace/omitted **user** or **system** `content` → `"."` |
| `null_tool_call_slots` | Drop `null` / `{}` slots in `tool_calls` |
| `stringify_arguments` | `tool_calls[].function.arguments` object → JSON string |
| `default_tool_call_type` | Missing/empty `tool_calls[].type` → `"function"` |
| `fill_tool_call_ids` | Empty `tool_calls[].id` → stable `call_` + hex; pair following empty `tool_call_id` |
| `unique_tool_call_ids` | Duplicate non-empty ids → suffix `_2`, `_3` (do not silent-dedup) |
| `sanitize_tool_schemas` | Inline local `$ref`, strip `$defs` / `$ref` / `$dynamicRef` / `$anchor`, clamp `pattern` `{n,m}` so `n` and `m` ≤ 1000 |
| `sanitize_json_schema` | Same sanitizer on `response_format.json_schema` |

**Dropped knobs** (`drop_unknown_knobs`): `extra_headers`, `think`, `cache_key`,
`prompt_cache_key`, `tags`, `routing_mode`, `json_mode`, `output_config`,
`fallback`, `allowed_token_ids`, `ignore_eos`, `use_beam_search`,
`truncate_prompt_tokens`, `prompt_logprobs`, `enable_search`, `search_kwargs`,
`mask_sensitive_info`, `partial`, `store`, `service_tier`, `metadata`,
`safety_identifier`, `prompt_cache_retention`.

## MiniMax wrap — default **off**

Older MiniMax hosts 400 on OpenAI `role:tool` strings
(`must be a non-empty array of {name,type,text} objects`). Current Gonka docs
([agents.md](https://github.com/gonka-ai/gonka/blob/main/docs/chat-api/agents.md))
use the standard OpenAI string. Wrapping a string-accepting gateway is a
regression (and can fight `flatten_content`). Enable wrap **only** after a live
400 with that substring. If you wrap, skip flattening those arrays.

## What is whose bug

| Symptom | Host | Client | Shim |
|---------|------|--------|------|
| Empty `tool_calls[].id` / `tool_call_id` | Right (id required) | Agent omitted id | `fill_tool_call_ids` |
| `$defs` / `$ref` / `definitions` / `$dynamicRef` | Narrower than agents (JSON Schema 2020-12) | Cursor/Zod/MCP | `sanitize_tool_schemas` / `sanitize_json_schema` |
| `pattern` with huge `{1,4096}` | RE2 on host | Schema from Zod | same sanitizers |
| Array `content: [{type,text}]` | Nodes want a string | OpenAI/OpenClaw parts | `flatten_content` |
| Blank `content` next to `tool_calls` | Recurring 400 | Agents send `""` | `blank_tool_content` |
| Empty user/system `content` | Host rejects `""` / whitespace / omit | Agents send blank turns | `fill_blank_user_system` |
| MiniMax `role:tool` string vs `[{name,type,text}]` | Older MiniMax/vLLM shape ([gonka#1467](https://github.com/gonka-ai/gonka/issues/1467), [#1475](https://github.com/gonka-ai/gonka/issues/1475)) | OpenAI string tool result | Wrap **only if** this gateway still 400s |
| `max_completion_tokens` | Unknown field | o1-style clients | `max_completion_tokens` |
| `reasoning_effort` aliases | Enum is `low`/`medium`/`high` | Clients | `reasoning_effort` |
| `extra_body` envelope / leaked `extra_headers` | Envelope is SDK transport | OpenAI SDK | `unwrap_extra_body` then `drop_unknown_knobs` |
| `response_format.json_schema` with `$ref` | Same as tools | Structured output | `sanitize_json_schema` |

Not this layer: 429s, empty upstream streams, TTFT hangs, Kimi empty
`tool_calls: []` with `tool_choice=required` (model/host behavior).

## Do not

- Put shims in the gateway
- Coerce `tool_choice: required` → `auto`
- Silent-dedup duplicate `tool_calls[].id`
- Drop `thinking` / `chat_template_kwargs` / `reasoning_details`
- Wrap MiniMax tool results by default (probe first)
- Follow remote `$ref` (SSRF)
- Log prompts or API keys

## Probe (use your own keys)

Against **your** proxy, then the same body against the gateway bypassing shims
if you have a staging path:

1. MiniMax + `tools[0].function.parameters` containing `$defs` + `$ref` →
   expect 400 `schema reference keyword is forbidden` without shims; 2xx or
   non-schema-400 with shims.
2. DeepSeek + history `tool_calls: [{id:"", ...}]` → expect 400
   `tool_calls[].id: must not be empty` without shims.
3. `pattern: "^.{1,4096}$"` in a tool property → expect pattern/RE2 400
   without clamp.
4. MiniMax multi-turn: assistant `tool_calls` + `role:tool` with string
   content → 400 array-shape only if wrap is still required.

See [reference.md](reference.md) for rewrite sketches and golden JSON.

## Related

`POST /v1/responses` is a separate adapter (ToChat → these shims → FromChat):
`broker-compat/responses-adapter/`.
