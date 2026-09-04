# Responses adapter sketches

Playbook from [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

Idempotent: a second `ToChat` pass must not mint extra tool ids or duplicate
system messages. SSE `sequence_number` starts at 0 and never resets mid-stream.

## Pipeline

`unwrap extra_body` (inside ToChat) → map fields → **chat body has no
Responses-only keys** (`store`, `include`, `truncation`, `previous_response_id`,
`client_metadata`, …) → hostcompat on that chat body → gateway → FromChat / SSE.

Hostcompat does not know `truncation` / `include`. If they leak, the host 400s
`unknown field`.

## Request: accept

| Responses | Chat |
|-----------|------|
| `model` | `model` |
| `input` string | `[{role:user, content}]` |
| `instructions` | Prepend `{role:system, content}` **first** |
| `input[]` `type:message` | `role` + string content. `developer` → `system`. Blocks `input_text` / `output_text` / `refusal` **flattened in ToChat** (hostcompat `flatten_content` skips non-`text` and would 400) |
| consecutive `function_call` items | **One** assistant message, `tool_calls[]`, `content: null` (not `""`) |
| `function_call_output` | `{role:tool, tool_call_id, content}`. `output` string or `input_text`/`output_text`/`text` blocks |
| `type: reasoning` | Stick on neighboring assistant as `reasoning_content`. Ignore `encrypted_content` |
| `type: compaction` | Drop |
| `tools[]` type=function (flat `{name, parameters, strict}`) | Nested `{type:function, function:{name, parameters, strict}}`. Pass through if already nested. **Do not invent `strict` if absent** |
| hosted tool types | Skip (see list). If `tools` empty after skip → omit `tools` |
| `tool_choice` string | As-is (`auto` / `none` / `required`) |
| `tool_choice` `{type:function, name}` | `{type:function, function:{name}}` |
| `max_output_tokens` | `max_tokens` if `max_tokens` absent |
| `text.format` json_schema | `response_format: {type:json_schema, json_schema:{name, schema, strict}}` |
| `text.format` json_object | `response_format: {type:json_object}` (v4 gateway may drop json_object — known) |
| `reasoning.effort` | `reasoning_effort` (aliases `max`→`high` are hostcompat) |
| `stream: true` | Same; internally set `stream_options.include_usage=true` |
| other chat-native knobs (`temperature`, `top_p`, `n`, `stop`, `seed`, `user`, `parallel_tool_calls` if not null, …) | Copy through if present |

Hosted skip list: `web_search`, `web_search_preview`, `file_search`,
`code_interpreter`, `computer_use`, `computer`, `computer_use_preview`,
`image_generation`, `mcp`, `shell`, `tool_search`.

Vision: `input_image` / `image_url` → chat `image_url` parts. Hosts that reject
`image_url` still 400 — that is not this adapter.

## Request: 400 JSON

Shape: `{"error":{"message":"…","type":"invalid_request_error","code":"…"}}`.

| `code` | When |
|--------|------|
| `previous_response_id_not_supported` | `previous_response_id` present |
| `conversation_not_supported` | `conversation` present |
| `background_not_supported` | `background: true` |
| `item_reference_not_supported` | `input` item `type: item_reference` |
| `hosted_tool_choice_not_supported` | `tool_choice.type` is hosted |
| `invalid_request` | missing `model` / `input`, bad JSON, unknown item type |

Message sense: *server-side state is not supported; send the full input on
each request (Codex/SDK session replay)*.

## Response JSON

Minimum:

```json
{
  "id": "resp_…",
  "object": "response",
  "created_at": 1710000000,
  "status": "completed",
  "model": "<echo request model>",
  "output": [],
  "output_text": ""
}
```

| Chat | Responses `output[]` |
|------|----------------------|
| assistant string | `type: message`, `content: [{type:output_text, text}]` |
| `reasoning_content` / `<think>` | `type: reasoning` **before** the message item |
| `tool_calls[]` | `type: function_call` with `id` (`fc_…`) **and** `call_id` (= chat tool id) |
| `finish_reason: length` | `status: incomplete`, `incomplete_details.reason=max_output_tokens` |
| `finish_reason: content_filter` | `incomplete` + `reason=content_filter` |
| `finish_reason: tool_calls` | `status` stays `completed` |
| `usage.prompt_tokens` | `usage.input_tokens` (also `output_tokens`, `total_tokens`) |

`output_text` = concatenation of `output_text` parts (canary/SDK read both).

## SSE (stream: true)

Emit `response.created` only after the **first upstream byte** (TTFT retry
must still be allowed to swap the host). Created payload is a **full**
response object (`id`, `object`, `created_at`, `model`, `status: in_progress`,
empty `output`) — not `{id, status}` only.

Every event has `sequence_number` starting at **0**. Item events have
`output_index`. Content events have `content_index` and `item_id`.
Function-call items need **both** `id` and `call_id` on `output_item.added`.

Text stream order (golden):

1. `response.created`
2. `response.in_progress`
3. `response.output_item.added` (message)
4. `response.content_part.added`
5. `response.output_text.delta` (repeating)
6. `response.output_text.done`
7. `response.content_part.done`
8. `response.output_item.done`
9. `response.completed` with `usage`

Tool stream: `output_item.added` (function_call) →
`response.function_call_arguments.delta` →
`function_call_arguments.done` → `output_item.done`.

Reasoning (`delta.reasoning_content` / `<think>` from thinking hosts): buffer,
emit one reasoning item (`added` → `done`) **before** the message item. Do not
invent `encrypted_content`. Optional `response.reasoning_text.delta` is not
required.

**Do not** send `data: [DONE]`. Terminal event is `response.completed`.
Chat `[DONE]` from upstream is swallowed.

Do not send `X-Reasoning-Included` (OpenAI-server header; a false value
breaks Codex reasoning-token accounting).

## Compact / GET by id

```http
POST /v1/responses/compact
→ 404 {"error":{"code":"compact_not_supported","message":"… use a custom Codex provider id (not openai) so Codex compacts locally"}}

GET /v1/responses/{id}
DELETE /v1/responses/{id}
→ 404 {"error":{"code":"not_found","message":"this broker does not store responses; send the full input on each request"}}
```

## Probe (your keys, your proxy)

1. `POST /v1/responses` `{"model":"…","input":"ping"}` → `object=response`,
   non-empty `output` or `output_text`.
2. Same with `"stream": true` → events include `response.created` and
   `response.completed`; body has **no** `[DONE]`.
3. `{"previous_response_id":"resp_x","model":"…","input":"x"}` → 400, not 200.
4. `POST /v1/responses/compact` with a key → 404 JSON, not a compacted item.
5. Chat `POST /v1/chat/completions` still 200 (adapter must not steal that path).

CompatCanary `--profile modern --timeout 120` is a regression check once chat
hosts are healthy.
