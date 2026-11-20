#!/usr/bin/env bash
# Install the modules of the installed NVIDIA driver branch for every installed kernel the archive serves.
# A newer kernel without them boots with no NVIDIA module. Prints "changed" when a package was installed.
set -Eeuo pipefail
meta="$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-modules-nvidia-*' 2>/dev/null \
  | awk '$2 ~ /^ii/ && $1 ~ /^linux-modules-nvidia-[0-9]+(-server)?(-open)?-generic$/ {print $1; exit}' || true)"
[[ -n "$meta" ]] || exit 0
branch="${meta#linux-modules-nvidia-}"; branch="${branch%-generic}"
running="$(uname -r)"
while IFS= read -r kernel; do
  package="linux-modules-nvidia-${branch}-${kernel}"
  dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' && continue
  apt-cache show "$package" >/dev/null 2>&1 || continue
  # An older kernel the host will not boot next may not resolve next to the installed driver.
  if [[ "$kernel" != "$running" ]] && dpkg --compare-versions "$kernel" lt "$running" \
    && ! apt-get install -s -o Debug::NoLocking=true "$package" >/dev/null 2>&1; then
    continue
  fi
  apt-get install -y "$package" >&2
  echo changed
done < <(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*-generic' 2>/dev/null \
  | awk '$2 ~ /^ii/ {sub(/^linux-image-/, "", $1); print $1}' || true)
