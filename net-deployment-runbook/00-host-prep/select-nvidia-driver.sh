#!/usr/bin/env bash
set -Eeuo pipefail

minimum_driver="${1:?usage: select-nvidia-driver.sh MINIMUM_DRIVER}"
[[ "$minimum_driver" =~ ^[0-9]+$ ]] || { echo 'minimum NVIDIA driver must be numeric' >&2; exit 2; }
apt_cache="${GDC_APT_CACHE:-apt-cache}"

selection="$(while IFS= read -r package; do
  [[ "$package" =~ ^nvidia-driver-([0-9]+)(-server)?(-open)?$ ]] || continue
  driver_major="${BASH_REMATCH[1]}"
  (( driver_major >= minimum_driver )) || continue
  candidate_version="$("$apt_cache" policy "$package" | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
  [[ -n "$candidate_version" && "$candidate_version" != '(none)' ]] || continue
  printf '%s\t%s\n' "$driver_major" "$package"
done < <("$apt_cache" pkgnames 'nvidia-driver-') \
  | sort -n -k1,1 -k2,2 \
  | tail -n1 \
  | cut -f2)"
[[ -n "$selection" ]] || exit 1
printf '%s\n' "$selection"
