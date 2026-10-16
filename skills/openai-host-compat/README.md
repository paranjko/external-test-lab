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
Use the companion [Responses adapter](../openai-responses-adapter/SKILL.md).
Obtain both folders from one explicitly approved full immutable repository
commit and verify it before manually copying reviewed folders into your
agent's configured skill directory. Do not install a moving branch or execute
a registry installer, and do not overwrite an existing skill without approval.
After `ToChat`, that adapter needs a host-compat layer — this catalog or the
equivalent already on the proxy.
