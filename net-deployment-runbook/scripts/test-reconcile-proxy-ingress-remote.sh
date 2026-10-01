#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit "${SUDO_EXIT:-0}"
EOF
chmod 0755 "$tmp/bin/sudo"
for expected in 0 17; do
  staging="$tmp/staging-$expected"
  mkdir -p "$staging/edge"
  if PATH="$tmp/bin:$PATH" SUDO_EXIT="$expected" "$ROOT/04-ops/edge-node/reconcile-proxy-ingress-remote.sh" "$staging" gdc-node0 0.0.0.0; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" == "$expected" ]]
  [[ ! -e "$staging" ]]
done
printf 'PASS remote proxy ingress cleanup preserves reconciliation status\n'
