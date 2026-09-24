#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${site_release_dir:-}"
number="${preview_number:-}"
revision="${preview_revision:-}"
origin="${PREVIEW_ORIGIN:-https://preview.gonka-dev.net}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
[[ -d "$release_dir" && ! -L "$release_dir" ]] || die 'site_release_dir is unavailable or unsafe'
[[ "$number" =~ ^[1-9][0-9]*$ && "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview identity is invalid'
[[ "$origin" =~ ^https://[A-Za-z0-9.-]+$ ]] || die 'PREVIEW_ORIGIN must be an HTTPS origin without a path'
manifest="$release_dir/preview-composition.json"
[[ -f "$manifest" && ! -L "$manifest" ]] || die 'preview composition manifest is unavailable or unsafe'
mode="$(jq -r '.mode // empty' "$manifest")"
[[ "$mode" =~ ^(static|backend|combined)$ ]] || die 'preview composition mode is invalid'

base="$origin/$number"
site_build="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' "$base/site-build.js")" || die 'public preview build metadata is unavailable'
observed_revision="$(sed -n 's/^window\.GDC_SITE_BUILD = \({.*}\);$/\1/p' <<<"$site_build" | jq -r '.revision // empty' 2>/dev/null || true)"
[[ "$observed_revision" == "$revision" ]] || die 'public preview revision does not match the selected source'
page="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' "$base/")" || die 'public preview page is unavailable'
[[ "$page" == *'<!doctype html'* || "$page" == *'<!DOCTYPE html'* ]] || die 'public preview did not return an HTML page'
if [[ "$mode" != static ]]; then
  status="$(curl --fail --silent --show-error --location --max-redirs 0 --connect-timeout 10 --max-time 30 --proto '=https' --proto-redir '=https' "$base/status/gpus")" || die 'source-bound GPU status route is unavailable'
  [[ "$status" != *'<html'* && "$status" != *'<!doctype'* && -n "$status" ]] || die 'source-bound GPU status route returned HTML or an empty body'
fi
printf 'PASS verified isolated public preview pr=%s revision=%s mode=%s\n' "$number" "$revision" "$mode"
