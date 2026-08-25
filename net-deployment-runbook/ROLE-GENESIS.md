# GENESIS: create the first Host

Genesis creates the network and its first Host

## Prerequisites

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host gdc-node0
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

## Create the network

```bash
gdc --release v2026.07.23 genesis gdc-node0 --public-edge gdc-node4
```

The command prepares the host, detects its public DNS and GPU, creates
Genesis, starts the first Host and makes authenticated inference ready. No
configuration file is required.

`--public-edge` identifies the Host serving the public website, API, and
Grafana. Omit it only when the Genesis Host serves those public endpoints.

If the SSH alias does not map to a detectable public DNS name, provide only
that missing value:

```bash
gdc --release v2026.07.23 genesis my-host --public-host node.example.net --public-edge public-edge-host
```

To create the chain without inference access:

```bash
gdc --release v2026.07.23 genesis gdc-node0 --no-bootstrap-access
```

To explicitly bypass the ML qualification gate, use:

```bash
gdc --release v2026.07.23 genesis gdc-node0 --skip-qualification
```

This records `ml_qualification=skipped_by_operator` in the Genesis evidence.
Skipping the gate does not disable the later node startup and authenticated
inference checks, so a host that cannot serve the configured model will still
fail the Genesis command.

The Host publishes a checksum-protected join bundle. It contains public chain
data only, never private keys or passwords.
