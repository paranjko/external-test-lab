#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo 'usage: read-join-mnemonic.sh (--mnemonic-prompt | --mnemonic-file <path>)' >&2
}

prompt=false
file=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mnemonic-prompt) prompt=true ;;
    --mnemonic-file)
      [[ -n "${2:-}" ]] || { usage; exit 2; }
      file="$2"
      shift
      ;;
    --mnemonic-file=*)
      file="${1#--mnemonic-file=}"
      [[ -n "$file" ]] || { usage; exit 2; }
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done

if [[ "$prompt" == true && -n "$file" ]]; then
  echo 'Error: --mnemonic-prompt and --mnemonic-file are mutually exclusive' >&2
  exit 1
fi
if [[ "$prompt" != true && -z "$file" ]]; then
  usage
  exit 2
fi

mnemonic=''
if [[ "$prompt" == true ]]; then
  if [[ ! -t 0 ]]; then
    echo 'Error: TTY required for interactive prompt' >&2
    exit 1
  fi
  read -s -r -p 'Enter mnemonic phrase: ' mnemonic
  echo >&2
else
  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: $file must be a regular file (symlinks prohibited)." >&2
    exit 1
  fi
  file_uid="$(stat -c %u "$file" 2>/dev/null || stat -f %u "$file")"
  if [[ "$file_uid" != "$(id -u)" ]]; then
    echo "Error: $file is not owned by current user." >&2
    exit 1
  fi
  file_perm="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")"
  case "$file_perm" in
    400|600) ;;
    *)
      echo "Error: insecure permissions ($file_perm) on $file. Run: chmod 600 $file" >&2
      exit 1
      ;;
  esac
  if jq -er '.mnemonic | strings' "$file" >/dev/null 2>&1; then
    mnemonic="$(jq -er '.mnemonic | strings' "$file")"
  else
    mnemonic="$(tr '\n' ' ' < "$file" | xargs)"
  fi
fi

word_count="$(wc -w <<<"$mnemonic")"
if [[ "$word_count" -ne 12 && "$word_count" -ne 24 ]]; then
  echo "Error: Invalid mnemonic length (got $word_count words, expected 12 or 24)." >&2
  unset mnemonic
  exit 1
fi

printf '%s\n' "$mnemonic"
unset mnemonic
