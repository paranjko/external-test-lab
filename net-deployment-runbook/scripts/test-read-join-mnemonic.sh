#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
READER="$ROOT/scripts/read-join-mnemonic.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mnemonic12='abandon ability able about above absent absorb abstract absurd abuse access accident'
mnemonic24="$mnemonic12 $mnemonic12"

printf '%s\n' "$mnemonic12" >"$tmp/plaintext"
chmod 0600 "$tmp/plaintext"
[[ "$("$READER" --mnemonic-file "$tmp/plaintext")" == "$mnemonic12" ]]

printf '{"mnemonic":"%s"}\n' "$mnemonic24" >"$tmp/backup.json"
chmod 0400 "$tmp/backup.json"
[[ "$("$READER" --mnemonic-file "$tmp/backup.json")" == "$mnemonic24" ]]

chmod 0644 "$tmp/plaintext"
if "$READER" --mnemonic-file "$tmp/plaintext" >"$tmp/insecure.out" 2>"$tmp/insecure.err"; then
  echo 'reader accepted insecure mnemonic file permissions' >&2
  exit 1
fi
grep -Fq "Run: chmod 600 $tmp/plaintext" "$tmp/insecure.err"

ln -s "$tmp/backup.json" "$tmp/link"
if "$READER" --mnemonic-file "$tmp/link" >"$tmp/link.out" 2>"$tmp/link.err"; then
  echo 'reader accepted a mnemonic symlink' >&2
  exit 1
fi
grep -Fq 'must be a regular file (symlinks prohibited)' "$tmp/link.err"

if "$READER" --mnemonic-prompt --mnemonic-file "$tmp/backup.json" >"$tmp/mutual.out" 2>"$tmp/mutual.err"; then
  echo 'reader accepted mutually exclusive mnemonic sources' >&2
  exit 1
fi
grep -Fxq 'Error: --mnemonic-prompt and --mnemonic-file are mutually exclusive' "$tmp/mutual.err"

if printf '%s\n' "$mnemonic12" | "$READER" --mnemonic-prompt >"$tmp/prompt.out" 2>"$tmp/prompt.err"; then
  echo 'reader accepted prompt input without a TTY' >&2
  exit 1
fi
grep -Fxq 'Error: TTY required for interactive prompt' "$tmp/prompt.err"

printf '%s\n' 'too short' >"$tmp/short"
chmod 0600 "$tmp/short"
if "$READER" --mnemonic-file "$tmp/short" >"$tmp/short.out" 2>"$tmp/short.err"; then
  echo 'reader accepted malformed mnemonic length' >&2
  exit 1
fi
grep -Fq 'Error: Invalid mnemonic length (got 2 words, expected 12 or 24).' "$tmp/short.err"
