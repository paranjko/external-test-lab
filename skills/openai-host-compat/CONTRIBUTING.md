# Contributing a host-compat shim

This folder is a **catalog**. Each broker implements the
rewrite on their own OpenAI HTTP proxy (`POST /v1/chat/completions`), before
the inference gateway.

`/v1/responses` belongs in the Responses adapter skill, not here:
`npx skills add paranjko/external-test-lab --skill openai-responses-adapter`
https://github.com/paranjko/external-test-lab/tree/main/skills/openai-responses-adapter

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
