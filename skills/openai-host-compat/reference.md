# Host-compat shim sketches

Playbook from [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

Idempotent: running twice must not mint a new id when one already exists,
or change a field that is already in the target shape.

## Apply order (log names)

Authenticate the caller first. Before JSON parsing enforce an 8 MiB request
body limit and depth 64 with a bounded parser. Across the entire request and
all transformations, share ceilings of 4,096 messages/input items, 256 tools,
1,024 tool calls, 4 MiB UTF-8 content, 1 MiB tool arguments, 16 MiB allocated
output and 100 ms monotonic transformation time. Count before copying or
concatenating; do not reset budgets for each shim, tool, item or adapter pass.
Use stack-safe traversal and stricter deployment limits where needed. The
schema-specific limits below also apply. Reject exhaustion with HTTP 413
`request_budget_exceeded`, no partial body and no upstream request. These
guards remain active when compatibility rewrites are disabled.

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

Canonicalize before model/tenant/route/tool authorization and quota decisions.
If earlier middleware already made such decisions, repeat them on the exact
final body immediately before forwarding. No later rewrite may add unchecked
fields. Authentication alone does not establish authorization of nested data.

`unwrap_extra_body` → `drop_unknown_knobs` → `drop_null_parallel_tool_calls` →
`max_completion_tokens` → `reasoning_effort` → `legacy_functions` →
`developer_role` → `flatten_content` → `blank_tool_content` →
`empty_content_array` → `fill_blank_user_system` → `null_tool_call_slots` → `stringify_arguments` →
`default_tool_call_type` → `fill_tool_call_ids` → `unique_tool_call_ids` →
`sanitize_tool_schemas` → `sanitize_json_schema`

## 1. Flatten content parts → string (`flatten_content`)

Input: `"content": [{"type":"text","text":"Hello"},{"type":"text","text":" world"}]`  
Output: `"content": "Hello world"`

Do **not** flatten:

- MiniMax tool-result parts `{name, type:"text", text}`
- Any non-text part (`image_url`, …) — leave the whole array

## 2. Fill empty tool call ids (`fill_tool_call_ids`)

For each `messages[i].tool_calls[j]`:

- If `id` is missing or `""`, set `id` to a short opaque value
  (`call_` + 8–24 hex). Same message, same index → same id if you rewrite twice
  in one request (hash of name+arguments+index is enough).
- Walk following `role: "tool"` messages with empty `tool_call_id` in order and
  assign pending ids 1:1. Pending is every assistant `tool_calls[].id` in
  order — already set or newly minted.
- Reset the pending id list when a new assistant `tool_calls` array appears.

Then `unique_tool_call_ids`: if two slots share a non-empty id, keep the first
and suffix later ones (`id_2`). Do not silent-dedup.

Also: `stringify_arguments` (object → JSON string) **before** hashing ids;
`default_tool_call_type` if `type` is empty; `null_tool_call_slots` drops
`null` / `{}` entries.

## 3. Schema keywords hosts forbid (`sanitize_tool_schemas`, `sanitize_json_schema`)

Walk `tools[].function.parameters` and `response_format.json_schema.schema`
(or `.json_schema`):

Before expansion, enforce bounded input parsing and stack-safe graph traversal.
Use these default per-request ceilings across all schemas, not fresh budgets
per tool: 1 MiB schema input, depth 64 (root depth 0), 1,024 resolved references,
10,000 expanded JSON values, 1 MiB expanded UTF-8 JSON, and 100 ms monotonic
elapsed time. Operators may choose stricter limits. Never disable limits;
larger production limits require explicit capacity testing. Count work and
output before allocating/copying, including repeated cached-reference copies;
check the deadline during traversal. Bound request parsing before constructing
deep objects, and use an explicit stack rather than language call recursion.

Track canonical JSON-Pointer targets on the active expansion path: reject a
self or mutual cycle, but allow repeated acyclic references within the shared
budgets. Reject unresolved/unsupported local references. On a cycle return
HTTP 400 with `error.code: schema_reference_cycle`; on any budget exhaustion
return HTTP 400 with `error.code: schema_budget_exceeded` (malformed references:
`schema_reference_invalid`). Do not forward a partial body, weaken the schema,
retry without sanitization, or expose schema contents in the error/log. Apply
the same protections to both schema surfaces and irrespective of shim toggles.

1. Resolve local `$ref` (`#/$defs/Foo`, `#/definitions/Foo`) by inlining.
2. Delete keys: `$defs`, `definitions`, `$ref`, `$dynamicRef`, `$dynamicAnchor`,
   `$anchor` (after inlining).
3. Recurse into every nested object and array, not only `properties`,
   `items`, `anyOf` / `oneOf` / `allOf`, `additionalProperties`.

If a `$ref` is external (`http://…`) and cannot be inlined, strip that subtree
or replace with `"type":"object"` — better a weaker schema than a 400. Do not
fetch remote refs.

The rejection cases in `golden/schema_rejections.json` are an implementation
contract, not proof that a broker enforces these limits. Run each against both
schema surfaces in the consuming proxy, assert the exact 400 code and zero
upstream requests, and use an injected monotonic clock for deadline tests.

## 4. RE2 `pattern` repeats (same sanitizers)

In every string `pattern`, replace `{low,high}` when `high > 1000` with
`{low,1000}`. If `low > 1000`, set `low = 1000` as well (so `{2000,4096}`
becomes `{1000,1000}`, not the invalid `{2000,1000}`). Also cap `{10000}`
(single bound) to `{1000}`. Do not invent a full regex parser; a conservative
replace on `{n,m}` digits is enough.

## 5. Blank content beside tool_calls (`blank_tool_content`, `empty_content_array`)

If `tool_calls` length > 0 and `content` is `""` or `[]`, set
`"content": null` (OpenAI assistant tool-call turn).

## 5b. Blank user/system content (`fill_blank_user_system`)

If `role` is `user` or `system` and `content` is missing, `null`, `""`,
whitespace-only, or `[]`, set `"content": "."`. Do **not** rewrite assistant
or tool turns (they already accept empty / null).

## 6. MiniMax tool-result wrap (conditional — **off by default**)

Only if a **live** probe 400s, `model` contains `minimax`, `role == "tool"`,
and `content` is a JSON string:

```json
{
  "role": "tool",
  "tool_call_id": "call_abc",
  "content": [
    {
      "name": "<function name from matching tool_calls>",
      "type": "text",
      "text": "<original string>"
    }
  ]
}
```

If `content` is already an array of `{name,type,text}`, leave it. Current
MiniMax-M2.7 docs use the OpenAI string; wrapping a string-accepting gateway
is a regression.

## 7. Knobs

- `max_completion_tokens`: copy → `max_tokens` if `max_tokens` absent; delete
  `max_completion_tokens`.
- `unwrap_extra_body`: accept one object envelope (`extra_body` or `extraBody`,
  not both). Only allow `reasoning_split`, `reasoning_effort`,
  `max_completion_tokens`, `parallel_tool_calls`, `thinking`,
  `chat_template_kwargs` and `reasoning_details`. Reject every other nested
  key, particularly model, tenant, user, route, endpoint, credentials,
  messages, instructions and tools. Reject duplicate JSON keys at parsing
  and any envelope key also present at top level, even with the same value.
  Return HTTP 400 `invalid_extra_body`, without forwarding. Lift the allowed
  fields, delete the envelope, then run `drop_unknown_knobs`. All lifted fields,
  including token limits and template settings, remain subject to final
  authorization and quota policy; an allowlist is not an authorization grant.
- Drop: `extra_headers`, `think`, `cache_key`, `prompt_cache_key`, `tags`,
  `routing_mode`, `json_mode`, `output_config`, `fallback`,
  `allowed_token_ids`, `ignore_eos`, `use_beam_search`,
  `truncate_prompt_tokens`, `prompt_logprobs`, `enable_search`,
  `search_kwargs`, `mask_sensitive_info`, `partial`, `store`, `metadata`,
  `service_tier`, `safety_identifier`, `prompt_cache_retention`.
  **Keep** `thinking`, `chat_template_kwargs`, `reasoning_details`.
- `reasoning_effort`: `max`, `maximum`, `extreme`, `highest` → `high`.
  Leave `low` / `medium` / `high` unchanged.
- `developer_role`: `role: "developer"` → `"system"`.
- `drop_null_parallel_tool_calls`: delete the key when value is `null`.
- `legacy_functions`: `functions` → `tools` when `tools` is absent;
  `function_call` → `tool_choice`.

## Golden 400 substrings (host)

Consumer security probes (run on both chat and Responses entrypoints): a
nested `model`/tenant/route must fail before forwarding; a nested token limit
must still pass final quota policy; duplicate top-level/envelope fields must
fail. Exercise each whole-request ceiling individually and aggregate many
small items to cross it; assert bounded termination and zero upstream calls.
The catalog specifies these tests, not a deployed implementation result.

- `schema reference keyword is forbidden`
- `"$defs" is not allowed` / `"$ref" is not allowed`
- `tool_calls[].id: must not be empty` / `must not be empty` near `tool_call`
- `invalid pattern` / RE2 repeat errors
- `must be a non-empty array of {name,type,text} objects` (MiniMax tool result)
