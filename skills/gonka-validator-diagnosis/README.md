# Gonka validator diagnosis

Version 1.0.0. Read-only validator membership and PoC admission investigation
for Gonka, using public chain evidence and optional authorized logs.

Download the versioned ZIP linked from the
[official trace page](https://gonka-dev.net/trace/#agent). Before extracting,
compare its SHA-256 with the exact value on that page. Stop on a mismatch;
do not install directly from a moving repository branch. Extract into a new
empty directory and review the included files and `SHA256SUMS` manifest.
The ZIP digest covers the entire package, including the file manifest.

Manually copy the reviewed `gonka-validator-diagnosis` folder into the receiving
agent's configured skill directory. Review the destination first and do not
overwrite an existing skill without approval. This activates instructions,
not the `gonkactl-trace` binary. No package-registry executable, Node.js/npm,
installer telemetry or automatic update is required.

Share this entire folder, not just `SKILL.md`. It contains the diagnosis
workflow, the trace collection reference and optional agent UI metadata.
There are no binaries, credentials, host inventories or incident datasets.

Place the folder in the receiving agent's configured skill directory, or
provide `SKILL.md` and its relative reference to an agent that can read local
files. No access to the author's project-management repository is required.

Example request:

```text
Use gonka-validator-diagnosis to explain why participant ADDRESS stopped
validating on NETWORK around HEIGHT or UTC TIME. Start with public evidence;
do not change the node. Report the membership decision separately from its
underlying cause and identify any missing evidence.
```

Install the optional collection CLI using the instructions at
[gonka-dev.net/trace](https://gonka-dev.net/trace/), as described in
`references/trace-collection.md`. Diagnostic records remain private by default;
sharing this skill does not authorize sharing collected reports or logs.

With a hosted agent, evidence included in its context is also sent to that
agent's provider. Use public or approved, scrubbed records; do not attach raw
private logs or credentials. Local report storage is not a promise that the
agent itself processes data offline.

Licensed under [Apache-2.0](LICENSE.txt).
