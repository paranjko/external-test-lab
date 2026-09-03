# Broker OpenAI compatibility

Specs for each broker's OpenAI HTTP proxy, **before** the inference gateway.

The catalogs (and the installable skills) live under `skills/`. Folder names
match the YAML `name`. These paths stay as pointers:

| | |
|---|---|
| Chat Completions host-compat | [`host-compat/`](host-compat/) → [`skills/openai-host-compat/`](../skills/openai-host-compat/) |
| Responses adapter (`POST /v1/responses`) | [`responses-adapter/`](responses-adapter/) → [`skills/openai-responses-adapter/`](../skills/openai-responses-adapter/) |

Install (one or both; not `--all` as the default):

```bash
npx skills add paranjko/external-test-lab --skill openai-host-compat
npx skills add paranjko/external-test-lab --skill openai-responses-adapter
```

Contributors PR into the skill folders (see each CONTRIBUTING). Do not publish
a parallel skills.sh skill for the same layer on your own.
