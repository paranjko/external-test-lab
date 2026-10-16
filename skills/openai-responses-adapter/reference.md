# Responses adapter sketches

Playbook from [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

Idempotent: a second `ToChat` pass must not mint extra tool ids or duplicate
system messages. SSE `sequence_number` starts at 0 and never resets mid-stream.

## Pipeline

Authenticate the caller, then bound parsing and canonicalize, then authorize
the exact final chat body and apply quota policy immediately before forwarding.
Model, tenant, route, tool and token policy must not rely on a pre-ToChat body;
repeat earlier policy checks after translation and host-compat rewrites.

Before parsing, cap the request at 8 MiB and JSON depth 64 with a bounded
parser. Share budgets across ToChat and host-compat: 4,096 messages/input
items, 256 tools, 1,024 tool calls, 4 MiB UTF-8 content, 1 MiB tool arguments,
16 MiB allocated output, and 100 ms monotonic transformation time. Count
before copies/concatenation, use stack-safe traversal, and never reset budgets
per item/pass. Retain stricter deployment limits and schema limits. Exhaustion
returns HTTP 413 `request_budget_exceeded` with no upstream call or partial
body. Limits apply even when compatibility flags are disabled.

Before the first client body read, start a non-resetting 30-second absolute
deadline and a 5-second inbound-idle deadline; cover headers/body acquisition,
decompression and parsing, including authentication middleware reads. Enforce
them even when no bytes arrive. On expiry stop reads, release the connection,
timers and buffers, return HTTP 408 `request_timeout` when writable, and never
forward upstream. Client disconnect cancels all request work immediately.
Use stricter configured limits; retries and adapter passes never reset clocks.

Incrementally cap wire and decompressed request bytes at 8 MiB each, aggregate
JSON values at 65,536, object members at 32,768, aggregate UTF-8 key bytes at
256 KiB, and aggregate decoded string bytes at 4 MiB. Cap total live request
parsing plus transformation memory at 16 MiB, including input buffers and
intermediate copies. Charge all fields before allocation, including fields
later stripped or ignored; depth and semantic limits also apply. Exhaustion
returns HTTP 413 `request_budget_exceeded` with cleanup and no upstream call.
Consumer tests must exercise slow/drip/silent bodies with a fake clock,
compressed expansion, shallow many-member objects, ignored-field floods,
long keys, allocation ceilings and disconnects; assert bounded memory, prompt
cleanup and zero forwarding. These are required consumer tests, not executed
runtime results claimed by this catalog.

For `extra_body`/`extraBody`, accept only one object envelope and the keys
`reasoning_split`, `reasoning_effort`, `max_completion_tokens`,
`parallel_tool_calls`, `thinking`, `chat_template_kwargs`, `reasoning_details`.
Reject duplicate JSON keys, top-level/envelope collisions and all other nested
keys (especially model, tenant, route, user, credentials, input, instructions
and tools) with HTTP 400 `invalid_extra_body`, before forwarding. Lifted fields
still require final field-dependent authorization and quota checks.

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

## Upstream response lifecycle (both modes)

Apply these limits to non-stream JSON and SSE alike, including error bodies:
8 MiB wire bytes and 8 MiB decoded bytes (count before decompression or buffer
growth), JSON depth 64, 65,536 aggregate JSON values, 4 MiB per string,
1 MiB aggregate tool arguments, and 16 MiB live parsing/transformation memory.
Use bounded, stack-safe parsing; check before allocation, copying and
concatenation. Share counters across parsing, FromChat and serialization.
Cap the full upstream operation at 120 seconds and idle time at 15 seconds,
including connection, headers and body reads; enforce deadlines even when no
bytes arrive. Stricter configured limits win. Retries do not reset budgets.

On any exhausted budget, cancel upstream and release all request resources.
For non-stream responses, return HTTP 502 with
`{"error":{"code":"response_budget_exceeded"}}`, never partial JSON or a
completed response. SSE uses the failure terminal described below.

Downstream disconnect or request-context cancellation must immediately
propagate to the upstream transport in both modes, stop reads/transformation
and timers, release buffers/connections and delete private spool files.
Use one idempotent cleanup path for success, failure and cancellation, including
races before headers and during output. Suppress all later downstream events
or writes after disconnect; do not wait for an idle or duration ceiling.

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

Buffering is bounded, not unlimited: cap reasoning at 1 MiB UTF-8, total
upstream response at 8 MiB, per-request live transformation memory at 16 MiB,
stream duration at 120 seconds and upstream idle time at 15 seconds. Count
bytes and check deadlines before allocation on every chunk; the transport
must also cancel a silent or stalled upstream. Apply stricter configured
limits when present. Never accumulate unbounded text while waiting for a
closing think marker or message. On exhaustion, cancel upstream immediately,
release buffers and emit exactly one `response.failed` terminal event with
`error.code: response_budget_exceeded` if SSE has started, or HTTP 502 with
that code otherwise. Do not emit `response.completed` or partial success.
If bounded spooling is used to preserve ordering, cap disk and memory together
and delete the private spool on success, failure and client disconnect.

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
6. Nested model/route/tenant fields and duplicate envelope keys fail before
   forwarding; final token/tool policy runs after all mappings.
7. Each input limit and an aggregate of individually small items fail with
   `request_budget_exceeded` and zero upstream calls.
8. Reasoning-only chunks exceeding the cap, a missing think terminator,
   a never-ending stream and an idle upstream each trigger bounded cancellation,
   one failure terminal, no completed event, and released memory/spool files.
   Use a fake clock and mock upstream; these are consumer implementation tests,
   not runtime results claimed by this instruction catalog.
9. Non-stream oversized wire/decoded bodies, excessive JSON depth/value count,
   oversized strings/tool arguments and transformation memory exhaustion fail
   before excess allocation with HTTP 502 `response_budget_exceeded` and no
   partial success. Slow headers, slow bodies and a silent upstream cancel at
   the shared deadline; retries cannot extend it. Use bounded mock transports
   and a fake clock, not real large allocations or live inference.
10. Disconnect clients before headers, during JSON reads and during SSE output.
    Assert prompt upstream cancellation, stopped timers, released connections
    and buffers, removed spools and no later downstream writes. Repeat concurrent
    disconnects and cancellation/success races: cleanup is idempotent and resource
    use returns to baseline without waiting for the response deadline.

CompatCanary `--profile modern --timeout 120` is a regression check once chat
hosts are healthy.
