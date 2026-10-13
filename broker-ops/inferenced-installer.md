# Inferenced installer: release selection and integrity

The generic installer accepts an optional version argument, the argument overrides `INFERENCED_VERSION`, without either it resolves the newest published `release/vX.Y.Z` tag as before

Accepted forms are `X.Y.Z`, `vX.Y.Z`, and `release/vX.Y.Z`, invalid or excess arguments fail before network access or installation

The installer requires `curl`, `unzip`, `awk`, `jq`, and either `sha256sum` or `shasum`, each download is bound to the selected official release tag, platform asset URL, and published SHA-256 digest

It also checks the extracted binary's version before replacing an existing installation, failures preserve the installed binary and never fall back to another release

Releases without a published asset SHA-256 are refused, digest verification is not an attestation or proof of source-build provenance

## DevNet callers

DevNet must select its release explicitly rather than constrain the generic installer

```sh
curl -fsSL https://gonka-dev.net/install_inferenced.sh | sh -s -- 0.2.15
```

For an attested downloaded installer, verify the installer separately, then pass the same explicit version

```sh
gh attestation verify install_inferenced.sh -R paranjko/external-test-lab
sh install_inferenced.sh 0.2.15
```

GDC's operator CLI remains profile-bound through `ensure-inferenced-cli.sh`, it does not call the generic installer without a version

The HTTPS installer endpoint and protected publication still require their separate live acceptance, local offline tests do not prove either
