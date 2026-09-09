# Native macOS operator and controlled JOIN

The operator workstation and target Host are different machines. The target
Host remains Linux AMD64 and uses Docker remotely. The operator can use a
modern Bash and compatible tools on macOS, without a local Docker daemon for
the generated-profile JOIN path. The [cleanroom](.devcontainer/cleanroom/README.md)
remains optional. Legacy release/composition commands may still invoke local
`docker buildx imagetools inspect`; this document does not certify all commands.

## Install and select native dependencies

On Intel or Apple Silicon, with Homebrew already installed:

```bash
brew install bash coreutils findutils gnu-sed gnu-tar flock jq openssl@3 python rsync
BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/opt/bash/bin:$BREW_PREFIX/opt/coreutils/libexec/gnubin:$BREW_PREFIX/opt/findutils/libexec/gnubin:$BREW_PREFIX/opt/gnu-sed/libexec/gnubin:$BREW_PREFIX/opt/gnu-tar/libexec/gnubin:$BREW_PREFIX/opt/openssl@3/bin:$BREW_PREFIX/bin:$PATH"
hash -r
bash --version
```

The developer test suite additionally validates JSON Schema. Install that
dependency in an isolated environment, it is not required to run `gdc` itself:

```bash
python3 -m venv .venv-runbook && source .venv-runbook/bin/activate && pip install jsonschema
```

Activate the environment rather than calling `.venv-runbook/bin/python`
directly: the tests spawn child scripts through `#!/usr/bin/env python3`, which
resolves from `PATH`.

Keep this PATH in the shell from which you invoke `gdc`; child scripts use
`#!/usr/bin/env bash` and inherit it. Do not launch with `/bin/bash` on macOS.
No changes to `/bin` or system tools are needed. Python handles IPv4 lookup;
GNU coreutils is not a replacement for Linux `getent`.

From `net-deployment-runbook`, run:

```bash
./gdc.sh --help
./scripts/test-gdc-preflight.sh
python3 ./scripts/test-resolve-ipv4.py
./scripts/test-native-operator.sh
```

The last test downloads the exact official Darwin artifact for a fixed test
release (0.2.15), verifies its tag/source and SHA-256, executes the CLI, and
checks disposable test-keyring creation and recovery into an isolated file
keyring. It blocks local Docker and SSH, removes its temporary keys, and is
not a live-network JOIN test. It requires network access to GitHub.

The launcher checks actual command semantics, Ed25519 derivation and FD lock
contention/release. Missing/incompatible dependencies fail before Host mutation.
A generated Join Profile binds an independent `components.operator_cli` to the
same observed Core version/commit and to its platform-specific archive digest.
Host Core/DAPI artifacts stay Linux artifacts. If an exact matching Darwin
artifact is unavailable, JOIN stops; it never falls back to another release.
Old retained profiles without `operator_cli` remain Linux AMD64 only. Do not
switch operator platform or replace a retained profile midway through JOIN;
continue that run in its original environment.

## Controlled manual JOIN

Use a disposable, designated Linux AMD64 Host meeting [Host requirements](ROLE-HOST.md)
and an unused participant identity. Do not reuse a live validator or its keys
for this test. `--verification` is **not a dry run**: JOIN changes the Host,
creates keys and can register/activate a participant. Coordinate the test Host
and public DNS with the network operator first.

1. Open a fresh native Mac terminal, apply the PATH above, and enter this
   working copy's `net-deployment-runbook`. Record `git rev-parse HEAD` and
   `git diff --stat`; uncommitted changes are not represented by HEAD alone.
2. Set the existing SSH alias and DNS for the designated test Host. Use a new
   local data root, isolated from all existing operator state:

   ```bash
   JOIN_ALIAS=gdc-native-test       # replace with the designated SSH alias
   JOIN_PUBLIC_HOST=test.example.net # replace with its actual public DNS
   export GDC_HOME="$HOME/.gdc-native-join-$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -m 700 "$GDC_HOME"
   ssh -T "$JOIN_ALIAS" 'uname -s; uname -m; id -u'
   python3 scripts/resolve-ipv4.py "$JOIN_PUBLIC_HOST"
   ./scripts/detect-public-host.sh "$JOIN_ALIAS" "$JOIN_PUBLIC_HOST"
   ```

   Confirm `Linux`, `x86_64`, the expected login privileges, and that DNS points
   to this Host. This read-only check does not establish that the Host is empty;
   confirm that independently before deployment.
3. To prove that JOIN does not use Docker locally, install a temporary PATH
   guard in this terminal only. It does not affect Docker over SSH:

   ```bash
   JOIN_GUARD_DIR="$(mktemp -d)"
   export GDC_LOCAL_DOCKER_LOG="$GDC_HOME/local-docker-attempts.log"
   cat >"$JOIN_GUARD_DIR/docker" <<'SH'
   #!/usr/bin/env bash
   printf 'unexpected local Docker invocation\n' >>"$GDC_LOCAL_DOCKER_LOG"
   echo 'local Docker disabled for native JOIN verification' >&2
   exit 99
   SH
   chmod 700 "$JOIN_GUARD_DIR/docker"
   export PATH="$JOIN_GUARD_DIR:$PATH"
   ./gdc.sh --help
   ```
4. Start the actual deployment when the test Host is ready:

   ```bash
   ./gdc.sh host join --verification --public-host "$JOIN_PUBLIC_HOST" "$JOIN_ALIAS"
   ```

   Keep this terminal open. Use the default Community DevNet only if that is
   the intended test network; otherwise use the reviewed `--bootstrap-file`
   from [ROLE-JOIN.md](ROLE-JOIN.md). Do not override runtime, lineage or
   signer checks to make the test pass.
5. Inspect the retained result and platform binding:

   ```bash
   jq '{operator:.spec.components.operator_cli.platform,target:.spec.target.platform,core:.spec.components.core.expected_runtime}' \
     "$GDC_HOME/$JOIN_ALIAS/state/join-profile.v1.json"
   find "$GDC_HOME/$JOIN_ALIAS/runs" -name join-result.v1.json -print
   test ! -s "$GDC_LOCAL_DOCKER_LOG"
   ```

   Read the result file printed for this run. Success requires the current
   JOIN acceptance checks, including lineage, state acquisition, signer,
   registration and backup; an installed CLI or a started container is not
   completion. Confirm the backup receipt/archive exists and retain it locally.
   If the run stops, save its terminal error, `state/preflight-receipt.env` and
   the run's `join-result.v1.json`. Review these before sharing: do not post
   mnemonics, passwords, private keys or the backup archive.

If `lineage_rpc_quorum_conflict` recurs, stop and investigate the network/RPC
receipts. Native platform support does not resolve a missing early checkpoint.
Do not immediately start over with another empty data root after Host mutation;
keep the same state for diagnosis and the documented resume procedure.

## Verification status

See [native-macos-validation.md](native-macos-validation.md) for the actual
checks performed on this change. Intel platform selection can be tested with
fixtures on Apple Silicon, but that is not an actual Intel Mac run. Full native
JOIN remains unverified until the controlled remote test above completes.
