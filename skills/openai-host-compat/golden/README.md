# Golden chat bodies

Minimal `in` → `out` for the host-compat pipeline. Toy payloads only (no real
prompts). Schema and comparison rules: [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

| File | What it pins |
|------|----------------|
| `flatten_content.json` | `{type,text}` parts → one string |
| `preserve_vision.json` | **Negative:** `image_url` arrays stay arrays (`shims` is `[]`) |
| `fill_tool_call_ids.json` | Empty `id` / `tool_call_id` paired (`call_` + opaque) |
| `stringify_arguments.json` | Arguments object → JSON string; missing `type` → `function` |
| `sanitize_tool_schemas.json` | Inline `$ref`, strip `$defs`, clamp `pattern` `{1,4096}` → `{1,1000}` |
| `sanitize_json_schema.json` | Same sanitizer on `response_format.json_schema` |
| `unwrap_extra_body.json` | Lift `extra_body`, drop unknown knobs, `max_completion_tokens` → `max_tokens` |
| `blank_tool_content.json` | Assistant `content: ""` next to `tool_calls` → `null` |
| `fill_blank_user_system.json` | Empty user/system → `"."`; assistant/tool stay empty |
| `unique_tool_call_ids.json` | Duplicate non-empty ids → `dup`, `dup_2` |
| `keep_thinking.json` | **Negative:** keep `thinking` and `chat_template_kwargs` (`shims` is `[]`) |
| `drop_null_parallel_tool_calls.json` | Delete `parallel_tool_calls` when `null` |
| `reasoning_effort.json` | `max` → `high` |
| `legacy_functions.json` | `functions` / `function_call` → `tools` / `tool_choice` |
| `developer_role.json` | `developer` → `system` |
| `null_tool_call_slots.json` | Drop `null` / `{}` slots in `tool_calls` |

Ports may differ on opaque `call_*` hex; pairing and idempotence are mandatory.
