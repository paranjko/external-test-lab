# Host-compat shim sketches

Playbook from [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

Idempotent: running twice must not mint a new id when one already exists,
or change a field that is already in the target shape.

## Apply order (log names)

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

1. Resolve local `$ref` (`#/$defs/Foo`, `#/definitions/Foo`) by inlining.
2. Delete keys: `$defs`, `definitions`, `$ref`, `$dynamicRef`, `$dynamicAnchor`,
   `$anchor` (after inlining).
3. Recurse into every nested object and array, not only `properties`,
   `items`, `anyOf` / `oneOf` / `allOf`, `additionalProperties`.

If a `$ref` is external (`http://…`) and cannot be inlined, strip that subtree
or replace with `"type":"object"` — better a weaker schema than a 400. Do not
fetch remote refs.

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
- `unwrap_extra_body`: copy nested keys onto the top level if absent, then
  delete the envelope. Then `drop_unknown_knobs`.
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

- `schema reference keyword is forbidden`
- `"$defs" is not allowed` / `"$ref" is not allowed`
- `tool_calls[].id: must not be empty` / `must not be empty` near `tool_call`
- `invalid pattern` / RE2 repeat errors
- `must be a non-empty array of {name,type,text} objects` (MiniMax tool result)
