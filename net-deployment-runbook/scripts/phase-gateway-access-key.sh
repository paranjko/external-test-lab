#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
credential="${2:-}"
[[ "$action" == list || ("$action" =~ ^(ensure|revoke)$ && "$credential" == telegram) ]] \
  || die 'expected: gateway access-key ensure telegram, revoke telegram, or list'

gateway_env=/srv/dai/ops/gateway.env
telegram_key_file="$SECRETS/gateway.telegram-client-key"

read_remote_keys() {
  ssh -T "$GATEWAY_NODE" "sudo awk -F= '\$1 == \"DEVSHARD_API_KEYS\" {print substr(\$0, index(\$0, \"=\") + 1); exit}' '$gateway_env'"
}

if [[ "$action" == list ]]; then
  remote_keys="$(read_remote_keys)"
  assurance_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
  case ",$remote_keys," in *",$assurance_key,"*) printf 'assurance configured\n' ;; *) printf 'assurance missing\n' ;; esac
  if [[ -s "$telegram_key_file" ]]; then
    telegram_key="$(<"$telegram_key_file")"
    case ",$remote_keys," in *",$telegram_key,"*) printf 'telegram configured\n' ;; *) printf 'telegram missing\n' ;; esac
  else
    printf 'telegram missing\n'
  fi
  exit 0
fi

if [[ "$action" == ensure ]]; then
  "$ROOT/scripts/make-secrets.sh" "$SECRETS" "$GENESIS_NODE" >/dev/null
fi
[[ -s "$telegram_key_file" ]] || die 'Telegram gateway credential does not exist'
telegram_key="$(<"$telegram_key_file")"
remote_keys="$(read_remote_keys)"
[[ -n "$remote_keys" ]] || die "DEVSHARD_API_KEYS is absent from $GATEWAY_NODE:$gateway_env"

case "$action" in
  ensure)
    case ",$remote_keys," in
      *",$telegram_key,"*) new_keys="$remote_keys" ;;
      *) new_keys="$remote_keys,$telegram_key" ;;
    esac
    ;;
  revoke)
    new_keys="$(tr ',' '\n' <<<"$remote_keys" | awk -v target="$telegram_key" 'NF && $0 != target' | paste -sd, -)"
    [[ -n "$new_keys" ]] || die 'refuse to remove the final gateway client credential'
    ;;
esac

if [[ "$new_keys" != "$remote_keys" ]]; then
  remote_tmp="/tmp/gdc-gateway-access-$$.env"
  ssh -T "$GATEWAY_NODE" "sudo cp '$gateway_env' '$remote_tmp'; sudo chown \$(id -u):\$(id -g) '$remote_tmp'; sed -i -E 's|^DEVSHARD_API_KEYS=.*|DEVSHARD_API_KEYS=$new_keys|' '$remote_tmp'; sudo install -o root -g root -m 0600 '$remote_tmp' '$gateway_env'; rm -f '$remote_tmp'; cd /srv/dai/ops; sudo docker compose --env-file .env --env-file gateway.env up -d --force-recreate devshard-gateway >/dev/null"
fi

if [[ "$action" == ensure ]]; then
  step 'Verify the dedicated Telegram credential with chain-accounted inference'
  "$ROOT/04-ops/test-inference-until-ready.sh" "https://$API_HOST" "$telegram_key" \
    "$GDC_HOME/runs/${GDC_RUN_ID:-gateway-access-key}/telegram-access" \
    "$GDC_HOME/runs/${GDC_RUN_ID:-gateway-access-key}/telegram-access.json" \
    "${GDC_GATEWAY_ACCESS_KEY_WAIT_SECONDS:-180}"
  printf 'PASS Telegram gateway credential configured\n'
else
  printf 'PASS Telegram gateway credential revoked\n'
fi
