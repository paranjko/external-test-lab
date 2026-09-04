# Contributing to the Responses adapter

This folder is a **catalog** for `POST /v1/responses` on a Gonka **broker**
OpenAI HTTP proxy (same process as chat-completions, **before** the inference
gateway). Translate Responses → chat, run a host-compat layer on that chat
body, translate the chat response (JSON or SSE) back.

It is a **spec**. PR the playbook, not a proxy binary. Any language on your
side.

Contributors are welcome. TestLab validates PRs against a live client path
and keeps contributor credit on this catalog. Prefer a PR here rather than
a parallel skills.sh listing for the same layer.

## What to add here

Typical PRs:

1. **ToChat** — a Responses request field or `input[]` item type that today
   400s, 405s, or drops context, with how it maps to chat-completions.
2. **FromChat / SSE** — a chat response or stream shape Codex/SDK needs
   (`response.created` after first upstream byte, no `data: [DONE]`,
   `sequence_number`, `call_id` + `id` on function-call items, …).
3. **400 vs strip** — a new Responses-only key: either a documented 400
   (`previous_response_id` class: client is relying on store) or strip
   (`store: true` class: SDKs send it by default).
4. **Probe** — a request you can replay with your own key that fails without
   the change and passes with it.

Need all of:

1. What the client sent (redact keys, no real prompts) and what broke
   (status + a stable error substring, or missing event name).
2. A row or paragraph in [SKILL.md](SKILL.md) and the matching sketch in
   [reference.md](reference.md).
3. Idempotent `ToChat`: a second pass must not mint extra tool ids or
   duplicate system messages.
4. Where it sits in 400 vs strip (if it is a request flag).

There is no `golden/` runner in this folder yet. A before/after sketch in
`reference.md` is enough for a first PR. Toy payloads only.

Chat-body rewrites belong in the host-compat skill
(`npx skills add paranjko/external-test-lab --skill openai-host-compat`).
https://github.com/paranjko/external-test-lab/tree/main/skills/openai-host-compat

## Do not

- Put Responses field maps or SSE notes in the host-compat skill
- Put prompts or API keys in the PR

## Review

TestLab reviews the spec against a live client path. Credit stays with the
contributor.
