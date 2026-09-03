# OpenAI Responses adapter

`POST /v1/responses` for a Gonka **broker** OpenAI HTTP proxy — **same process**
as `POST /v1/chat/completions`, **before** the inference gateway. Translate
Responses → chat-completions, run host-compat shims on that chat body, then
translate the chat response (JSON or SSE) back to Responses.

This is a spec to implement on the proxy. It is not code to drop in.

Developed by [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

```
Codex / Agents SDK
    → POST /v1/responses
    → ToChat
    → host-compat shims (chat body)
    → gateway → host
    → FromChat / SSE translator
```

Chat Completions stays for Cursor / chat-mode Cline / most SDKs. This path is
for clients that **hard-call** Responses (Codex CLI, Agents SDK
`client.responses.create()`).

| File | What |
|------|------|
| [SKILL.md](SKILL.md) | Catalog, 400 vs strip, Codex provider, probes |
| [reference.md](reference.md) | Field maps, SSE order, error codes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to add a mapping / 400-vs-strip / probe |

After `ToChat`, run a host-compat layer on the chat body — this catalog or
the equivalent already on the proxy:
[`broker-compat/host-compat/`](../host-compat/).
