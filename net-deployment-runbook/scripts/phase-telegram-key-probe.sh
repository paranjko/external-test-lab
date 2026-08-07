#!/usr/bin/env bash
set -Eeuo pipefail

# Controlled evidence action for the private assurance adapter.  It exercises
# the bot's real `issue()` path with a synthetic ID outside Telegram's valid
# integer range,
# verifies the resulting credential through the bot's own authenticated chat
# contract, and deletes only that temporary row before returning.  It never
# prints an API key or touches an operator's existing assignment.
source "$(dirname "$0")/lib.sh"
load_project
record_phase_profile telegram-key-probe

model="${1:-}"
sla="${2:-}"
[[ "$model" == "$MODEL_ID" ]] || die "telegram-key-probe model must be $MODEL_ID"
[[ "$sla" =~ ^[1-9][0-9]*(ms|s|m|h)$ ]] || die 'telegram-key-probe SLA must be a positive wall-clock duration'
case "$sla" in
  *ms) sla_ms="${sla%ms}" ;;
  *s) sla_ms="$(( ${sla%s} * 1000 ))" ;;
  *m) sla_ms="$(( ${sla%m} * 60000 ))" ;;
  *h) sla_ms="$(( ${sla%h} * 3600000 ))" ;;
esac

bot_host="${GDC_TELEGRAM_BOT_HOST:-gdc-node4}"
[[ "$bot_host" == gdc-node0 || "$bot_host" == gdc-node4 ]] || die 'GDC_TELEGRAM_BOT_HOST must be gdc-node0 or gdc-node4'
# Telegram IDs are bounded to 52 significant bits.  This signed 64-bit value
# cannot collide with a real account/group assignment, yet remains valid for
# SQLite INTEGER PRIMARY KEY storage.
temporary_id="$(( -9000000000000000000 + ( $$ % 1000000 ) * 1000 + RANDOM ))"
probe_program="$ROOT/scripts/telegram-bot/assurance_probe.py"
[[ -r "$probe_program" ]] || die "missing Telegram assurance probe: $probe_program"

step "Issue and verify one temporary Telegram API key on $bot_host"
result="$(ssh -T "$bot_host" "set -Eeuo pipefail
  bot=\"\$(docker ps -q --filter name=gonka-devnet-bot-bot | head -1)\"
  [[ -n \"\$bot\" ]]
  docker exec -i \
    -e GDC_ASSURANCE_TEMP_TELEGRAM_ID='$temporary_id' \
    -e GDC_ASSURANCE_SLA_MS='$sla_ms' \
    \"\$bot\" python3 -" < "$probe_program")"

jq -e '.created == true and .verified == true and .within_sla == true and .temporary_assignment_cleaned == true' <<<"$result" >/dev/null \
  || die 'Telegram issuer could not create, verify, and clean up a temporary API key within the SLA'
jq -cn --arg model "$model" --arg sla "$sla" --argjson probe "$result" \
  '{outcome:"PASS",model:$model,inference_sla:$sla,elapsed_ms:$probe.elapsed_ms,within_sla:$probe.within_sla,issued_key_receipt:"temporary-telegram-assignment",inference_receipt:"temporary-telegram-key-authenticated-chat",temporary_assignment_cleaned:$probe.temporary_assignment_cleaned}'
