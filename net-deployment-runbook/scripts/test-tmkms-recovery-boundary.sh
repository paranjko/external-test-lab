#!/usr/bin/env bash
# Disposable exact-binary probe. No production keys or network access.
set -Eeuo pipefail
umask 077
hex() { od -An -v -tx1 | tr -d ' \n'; }
bytes() {
  local input="$1" escaped=''
  while [[ -n "$input" ]]; do escaped+="\\x${input:0:2}"; input="${input:2}"; done
  printf '%b' "$escaped"
}
varint() {
  local value="$1"
  while ((value > 127)); do printf '%02x' "$(((value & 127) | 128))"; value=$((value >> 7)); done
  printf '%02x' "$value"
}
integer() { varint "$(($1 << 3))"; varint "$2"; }
blob() { varint "$((($1 << 3) | 2))"; varint "$((${#2} / 2))"; printf '%s' "$2"; }
# Hex parsing keeps NUL bytes out of Bash variables. Cursor and value are globals.
readvar() {
  local byte shift=0
  value=0
  while ((cursor + 2 <= ${#data} && shift < 63)); do
    byte=$((16#${data:cursor:2})); cursor=$((cursor + 2))
    value=$((value | ((byte & 127) << shift)))
    ((byte >= 128)) || return 0
    shift=$((shift + 7))
  done
  return 1
}
field() {
  local data="$1" wanted="$2" cursor=0 value=0 tag wire size
  while ((cursor < ${#data})); do
    readvar; tag=$((value >> 3)); wire=$((value & 7))
    case "$wire" in
      0) readvar; if ((tag == wanted)); then printf '%s' "$value"; return; fi ;;
      2)
        readvar; size=$((value * 2))
        ((cursor + size <= ${#data})) || return 1
        if ((tag == wanted)); then printf '%s' "${data:cursor:size}"; return; fi
        cursor=$((cursor + size)) ;;
      *) return 1 ;;
    esac
  done
  return 1
}
if [[ ${1:-} == --session ]]; then
  cat request
  prefix=''
  for ((i=0; i<9; i++)); do
    byte="$(dd bs=1 count=1 status=none | hex)"
    if [[ -z "$byte" ]]; then printf closed >response-status; exit 0; fi
    prefix+="$byte"
    if ((16#$byte < 128)); then break; fi
  done
  data="$prefix"; cursor=0; readvar
  ((value > 0 && value < 4096)) || exit 1
  dd bs=1 count="$value" status=none >response
  [[ $(wc -c <response) == "$value" ]] || exit 1
  printf received >response-status
  exit 0
fi
script="$(readlink -f "$0")"
temp="$(mktemp -d)"; signer_pid=''; socket_pid=''
cleanup() {
  [[ -z "$signer_pid" ]] || { kill "$signer_pid" 2>/dev/null || :; wait "$signer_pid" 2>/dev/null || :; }
  [[ -z "$socket_pid" ]] || { kill "$socket_pid" 2>/dev/null || :; wait "$socket_pid" 2>/dev/null || :; }
  rm -rf "$temp"
}
trap cleanup EXIT
cd "$temp"
openssl rand 32 >seed
base64 <seed >key
{ bytes 302e020100300506032b657004220420; cat seed; } >key.der
openssl pkey -inform DER -in key.der -pubout -out public.pem
printf '%s\n' '{"height":"523800","round":"2147483647","step":127,"block_id":null}' >state.json
cat >config.toml <<CONFIG
[[chain]]
id = "isolated-boundary-test"
key_format = { type = "bech32", account_key_prefix = "testpub", consensus_key_prefix = "testvalconspub" }
state_file = "state.json"
[[validator]]
addr = "unix://$temp/signer.sock"
chain_id = "isolated-boundary-test"
reconnect = true
protocol_version = "v0.34"
[[providers.softsign]]
chain_ids = ["isolated-boundary-test"]
key_format = "base64"
path = "key"
CONFIG
chain_hex="$(printf isolated-boundary-test | hex)"
for scenario in 523799:0 523800:0 523800:2147483647 523801:0; do
  height="${scenario%:*}"; round="${scenario#*:}"
  vote="$(integer 1 2)$(integer 2 "$height")$(integer 3 "$round")$(blob 5 "$(integer 1 1780000000)")$(blob 6 "$(printf '%040d' 0)")"
  request_hex="$(blob 3 "$(blob 1 "$vote")$(blob 2 "$chain_hex")")"
  bytes "$(varint "$((${#request_hex} / 2))")$request_hex" >request
  rm -f signer.sock response response-status
  timeout 20s socat "UNIX-LISTEN:$temp/signer.sock" "EXEC:bash $script --session" >socket.log 2>&1 &
  socket_pid=$!
  for ((i=0; i<100; i++)); do [[ ! -S signer.sock ]] || break; sleep 0.05; done
  [[ -S signer.sock ]]
  tmkms start -c config.toml >process.log 2>&1 & signer_pid=$!
  if ! wait "$socket_pid"; then cat socket.log process.log >&2; exit 1; fi
  socket_pid=''
  kill "$signer_pid" 2>/dev/null || :
  wait "$signer_pid" 2>/dev/null || :
  signer_pid=''
  if ((height <= 523800)); then
    jq -e '.height == "523800"' state.json >/dev/null
    if [[ $(<response-status) == closed ]]; then
      expected='round regression'
      ((height >= 523800)) || expected='height regression'
      grep -q "$expected" process.log
    else
      signed="$(field "$(hex <response)" 4)"
      [[ -n "$(field "$signed" 2)" ]]
    fi
    printf 'PASS refused height=%s round=%s without advancing state\n' "$height" "$round"
  else
    [[ $(<response-status) == received ]]
    signed="$(field "$(hex <response)" 4)"
    if field "$signed" 2 >/dev/null; then echo 'unexpected signer error' >&2; exit 1; fi
    returned_vote="$(field "$signed" 1)"
    signature_hex="$(field "$returned_vote" 8)"
    [[ ${#signature_hex} == 128 && $(field "$returned_vote" 1) == 2 && $(field "$returned_vote" 2) == "$height" ]]
    little=''; number="$height"
    for ((i=0; i<8; i++)); do little+="$(printf '%02x' "$((number & 255))")"; number=$((number >> 8)); done
    canonical="$(integer 1 2)11$little$(blob 5 "$(field "$returned_vote" 5)")$(blob 6 "$chain_hex")"
    bytes "$(varint "$((${#canonical} / 2))")$canonical" >signbytes
    bytes "$signature_hex" >signature
    openssl pkeyutl -verify -pubin -inkey public.pem -rawin -in signbytes -sigfile signature
    jq -e '.height == "523801"' state.json >/dev/null
    echo 'PASS cryptographically verified signature above boundary and persisted height'
  fi
done
