#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  https://preview.example/220/|https://preview.example/220/site-build.js|https://preview.example/220/status/gpus) ;;
  *) echo "unexpected URL: $url" >&2; exit 97 ;;
esac
printf '%s\n' "$url" >>"$PREVIEW_PROBE_LOG"
if [[ "$url" == */status/gpus ]]; then
  printf '%s' "${PREVIEW_TEST_STATUS:-404}"
  exit "${PREVIEW_TEST_EXIT:-0}"
fi
printf '404'
SH
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" PREVIEW_PROBE_LOG="$tmp/calls" preview_number=220 PREVIEW_ORIGIN=https://preview.example
bash "$root/scripts/verify-removed-site-preview-live.sh"
[[ "$(wc -l <"$tmp/calls")" == 3 ]]
for status in 200 301 403 502; do
  if PREVIEW_TEST_STATUS="$status" bash "$root/scripts/verify-removed-site-preview-live.sh"; then
    echo "false removal success for HTTP $status" >&2; exit 1
  fi
done
if PREVIEW_TEST_EXIT=7 bash "$root/scripts/verify-removed-site-preview-live.sh"; then
  echo 'connection failure was treated as successful removal' >&2; exit 1
fi
printf 'PASS removal verifier requires HTTP 404 on every public route\n'
