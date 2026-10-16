# RTX 5090: independent 7B and 4B workers

Candidate layout, not a general hardware qualification claim. Keep the existing
Host participant and consensus services. Add one separate ML API and internal
router; do not publish their ports or create another validator identity.

Do not deploy this dual layout while the effective 7B epoch arguments contain
`--gpu-memory-utilization 0.92`. DAPI gives epoch arguments priority over local
arguments: 7B then cannot restart while 4B occupies the GPU. A successful
7B-first cold start does not qualify recovery. Resolve this network-level
prerequisite explicitly or deploy only one model; this layout does not change
governance or bypass argument precedence.

Both models use pinned BF16 weights, eager execution, four sequences and an
explicit 2 GiB KV cache. Primary 7B retains a 4096-token context; secondary 4B
retains 25000. Startup free-memory checks use fractions 0.58/0.32. The explicit
KV budgets replace automatic KV sizing, but do not cap every CUDA allocation.
Both workers chunk prefill into at most 512 tokens to reduce activation peaks;
this does not reduce their context limits.
Measure loading and concurrent PoC peaks before accepting this layout.

`bash render.sh PARTICIPANT NEW_DIRECTORY` renders the primary model map and
secondary DAPI worker only. It performs no transport or deployment. Preserve
the current node configuration and receipts before changing anything.

Set `HF_CACHE_ROOT` to the existing cache bind and `HOST_DOCKER_NETWORK` to
the existing Host network when rendering Compose. Prefetch both exact revisions
before setting offline mode. Only one instance of this layout may share a
Host network because its internal DNS aliases are fixed.

Only the Hugging Face `hub` directory is mounted read-only. The container's
remaining cache stays writable for FlashInfer JIT compilation and logs.
Mounting all of `/root/.cache` read-only prevents the inference engine starting.
The secondary explicitly preserves its network model name because offline
vLLM resolution otherwise substitutes a local snapshot path as the served name.

Deployment requires an inference window, no ML locks or preserved work, fresh
empty version-bound DevShard obligations and coordination with traffic owners.
Use the existing reviewed Host model transition for the primary worker, then
verify healthy 7B before registering the secondary worker. Preserve the mounted
node-config inode and every unrelated worker. Registration alone is not health.

Acceptance requires both exact models loaded, direct completions, simultaneous
PoC/cPoC numerical agreement, recovery, effective network admission and signing.
Before rollback, recheck obligations and remove only the newly added worker;
keep caches, keys, chain data and failed-attempt receipts. Never run JOIN again
or restart consensus to change an ML layout.

## Host HTTPS prerequisite

A pre-existing web server may occupy ports 80/443 while GDC's Caddy repeatedly fails.
Check listener ownership and all active virtual hosts before changing services.
Do not blindly disable nginx: it may serve unrelated applications. If its only
configuration is a confirmed reject-all bootstrap placeholder, preserve its
configuration and service state, disable that placeholder service and restart
only the participant's edge. Verify valid public TLS and chain/API routes.
Healthy local ML cannot compensate for unreachable public PoC proof endpoints.

Run `make test` here for offline renderer and Compose checks. These checks do
not start containers or prove runtime acceptance.
