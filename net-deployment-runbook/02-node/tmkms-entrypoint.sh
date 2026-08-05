#!/bin/sh
set -eu

: "${CHAIN_ID:?CHAIN_ID is required}"

for config in /app/tmkms_init_data/tmkms.toml /root/.tmkms/tmkms.toml; do
  [ ! -f "$config" ] || sed -i \
    -e "s/^id = \".*\"/id = \"$CHAIN_ID\"/" \
    -e "s/^chain_ids = \[.*\]/chain_ids = [\"$CHAIN_ID\"]/" \
    -e "s/^chain_id = \".*\"/chain_id = \"$CHAIN_ID\"/" \
    "$config"
done

exec /root/init.sh
