# OpenAI host-compat shims

Catalog of request rewrites for a Gonka **broker** OpenAI HTTP proxy
(`POST /v1/chat/completions`), **before** the inference gateway. Agent clients
(Cursor, Cline, Zod, MCP) send bodies that stricter MiniMax / Kimi / DeepSeek
hosts 400; these steps reshape the JSON so the host validator accepts it.

This is a spec to implement on the proxy. It is not code to drop in.

Developed by [Dahl](https://inference.dahl.global) together with
[Gonka External TestLab](https://github.com/paranjko/external-test-lab).

```
Agent → broker proxy (this catalog) → gateway → host validator → model
```

| File | What |
|------|------|
| [SKILL.md](SKILL.md) | Catalog, apply order, whose bug, probes |
| [reference.md](reference.md) | Before/after sketches |
| [golden/](golden/) | Toy `in` → `out` JSON |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to add a shim |

Codex / Agents SDK (`POST /v1/responses`) is a separate skill.
Install: `npx skills add paranjko/external-test-lab --skill openai-responses-adapter`
https://github.com/paranjko/external-test-lab/tree/main/skills/openai-responses-adapter
After `ToChat`, that adapter needs a host-compat layer — this catalog or the
equivalent already on the proxy.
