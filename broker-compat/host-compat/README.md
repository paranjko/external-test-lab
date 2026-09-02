# OpenAI host-compat shims

Catalog of request rewrites for a Gonka **broker** OpenAI HTTP proxy
(`POST /v1/chat/completions`), **before** the inference gateway. Agent clients
(Cursor, Cline, Zod, MCP) send bodies that stricter MiniMax / Kimi / DeepSeek
hosts 400; these steps reshape the JSON so the host validator accepts it.

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

Codex / Agents SDK (`POST /v1/responses`) is a separate layer:
[`broker-compat/responses-adapter/`](../responses-adapter/). After
`ToChat`, that adapter must run **this** catalog on the chat body.
