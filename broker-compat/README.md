# Broker OpenAI compatibility

| | |
|---|---|
| Chat Completions host-compat | [`host-compat/`](host-compat/) → [`skills/openai-host-compat/`](../skills/openai-host-compat/) |
| Responses adapter (`POST /v1/responses`) | [`responses-adapter/`](responses-adapter/) → [`skills/openai-responses-adapter/`](../skills/openai-responses-adapter/) |

## How to use

This is a spec to port onto an existing proxy. It is not code to drop in.

Pick one or both (not `--all` as the default):

- Chat Completions host 400s (Cursor, Cline, most SDKs) → `openai-host-compat`
- Codex / Agents SDK (`POST /v1/responses`) → `openai-responses-adapter`. After `ToChat`, that chat body still needs a host-compat layer — this catalog or the equivalent already on the proxy.

```bash
npx skills add paranjko/external-test-lab --skill openai-host-compat
npx skills add paranjko/external-test-lab --skill openai-responses-adapter
```

Follow the skill's `SKILL.md` and `reference.md`. Port after auth, before the
gateway. Do not start a new process.
