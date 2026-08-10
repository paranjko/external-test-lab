# DEVELOPER: use inference

A Developer needs the public API URL, a client API key and a model name. The
Developer does not operate a Host, Gateway or OPS service.

```bash
curl https://api.gonka-dev.net/v1/models \
  -H 'Authorization: Bearer <client-api-key>'

curl https://api.gonka-dev.net/v1/chat/completions \
  -H 'Authorization: Bearer <client-api-key>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}]}'
```

This is a test network. A temporary unavailable response is valid when no
DevShard runtime is ready; an invented response is not.
