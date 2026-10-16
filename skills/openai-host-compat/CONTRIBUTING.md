# Contributing a host-compat shim

This folder is a **catalog**. Each broker implements the
rewrite on their own OpenAI HTTP proxy (`POST /v1/chat/completions`), before
the inference gateway.

`/v1/responses` belongs in the Responses adapter skill, not here:
[Responses adapter](../openai-responses-adapter/SKILL.md). Use reviewed local
folders from the same approved immutable commit; see the skill's manual-copy
installation boundary, not a registry installer or moving branch.

## Add a shim

Need all of:

1. A **live** 400 (or equivalent validator reject) and a stable substring from
   the error body (redact keys).
2. An **idempotent** rewrite (second pass must not mint a new id or change a
   field already in the target shape).
3. A **log name** (snake_case, same as `id` / `shims` in the golden).
4. A golden: `golden/<log_name>.json`.
5. A row in `SKILL.md` and a sketch in `reference.md`, with a slot in the
   existing apply order.

PR is a **spec**. No need to submit Go/Python.

Do not put real prompts, emails, API keys, or chat logs in goldens or issues.

## Golden file

```json
{
  "id": "flatten_content",
  "shims": ["flatten_content"],
  "host_400_substring": "optional, from a live 400",
  "notes": "optional",
  "in": {},
  "out": {}
}
```

- `id` — filename without `.json`.
- `shims` — names that fire on `in`, in pipeline order. `[]` = negative case
  (pipeline must leave the fixture alone).
- `in` / `out` — minimal chat-completions JSON. Toy strings only.

Compare `out` after JSON parse (key order irrelevant). Opaque `tool_calls[].id`
values may differ across ports if they stay non-empty, use a `call_` prefix,
match the paired `tool_call_id`, and do not change on a second pass.

One request that fires several shims → one file listing all of them in `shims`.

### Schema rejection suite

`golden/schema_rejections.json` is a separate negative-test format. Each case
has a schema, optional stricter test limits, and an expected HTTP status/error
code. Wrap every schema as both `tools[0].function.parameters` and
`response_format.json_schema.schema` in separate requests. Limits override
only the named default for the test; all other reference limits still apply.
Assert no upstream request, no partial output and bounded termination. The
deadline case injects an already-expired monotonic deadline. Also send multiple
individually valid tools whose aggregate exceeds a budget to verify that
budgets are shared. This catalog does not contain an executable sanitizer;
fixture parsing alone is not runtime security verification.
