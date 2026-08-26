# Laboratory Candidate Definitions

Files in this directory freeze independent External Test Lab candidates. They
are not official Gonka releases or readiness statements.

Each `*.definition.json` records exact source commits, source trees, component
boundaries, build arguments, architectures, base-image digests, enabled
features, explicit exclusions, and the upstream qualification state observed
when the candidate was frozen. Its adjacent `*.definition.sha256` file binds
the bytes consumed by reviewed default-branch automation.

The lifecycle is:

```bash
./gdc.sh release candidate prepare --source-ref upgrade-v0.2.16
./gdc.sh release candidate build v2026.08.25-rc.0 --wait
./gdc.sh release candidate profile v2026.08.25-rc.0
./gdc.sh release candidate verify v2026.08.25-rc.0
```

`prepare` is idempotent for an already frozen source. `build` dispatches only
the reviewed workflow on `main`, resumes an existing matching run, and never
grants package or attestation authority to pull-request code. The build emits
OCI digests, provenance, SBOMs, checksum-bound upgrade archives, and deployable
image archives. `profile` refuses to overwrite a different lock, and `verify`
reconstructs the lock from the immutable definition and build manifest.

Generated release locks belong under `profiles/releases/` and require their
own reviewed change before live use.
