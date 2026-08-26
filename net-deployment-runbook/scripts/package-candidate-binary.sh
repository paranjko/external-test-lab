#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 3 ]] || {
  echo 'usage: package-candidate-binary.sh COMPONENT PACKAGE_DIR ARCHIVE' >&2
  exit 2
}

component="$1"
package_dir="$2"
archive="$3"

case "$component" in
  inferenced|inferenced-operator|decentralized-api|edge-api|devshardd) ;;
  *)
    echo "unsupported candidate binary component: $component" >&2
    exit 2
    ;;
esac

[[ -d "$package_dir" ]] || {
  echo "candidate binary package directory is missing: $package_dir" >&2
  exit 1
}

# BuildKit preserves the binary-exporter destination directory and all of its
# runtime companions. Validate that exact pinned layout, then isolate only the
# requested executable for the Cosmovisor/operator archive.
case "$component" in
  inferenced)
    expected_entries=$'inferenced\nlibgcc_s.so.1\nlibwasmvm_muslc.x86_64.a\nwrapped_token.wasm'
    export_dir="$package_dir/build_output"
    binary_name=inferenced
    ;;
  inferenced-operator)
    expected_entries=inferenced
    export_dir="$package_dir/build_output"
    binary_name=inferenced
    ;;
  decentralized-api)
    expected_entries=$'decentralized-api\ninferenced\nlibgcc_s.so.1\nlibwasmvm_muslc.x86_64.a'
    export_dir="$package_dir/build_output"
    binary_name=decentralized-api
    ;;
  edge-api)
    expected_entries=$'edge-api\nlibgcc_s.so.1'
    export_dir="$package_dir/build_output"
    binary_name=edge-api
    ;;
  devshardd)
    expected_entries=devshardd
    export_dir="$package_dir"
    binary_name=devshardd
    ;;
esac

[[ -d "$export_dir" ]] || {
  echo "candidate binary export directory is missing for $component: $export_dir" >&2
  exit 1
}
if [[ "$export_dir" != "$package_dir" ]]; then
  root_entries="$(find "$package_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
  [[ "$root_entries" == build_output && -d "$package_dir/build_output" ]] || {
    echo "candidate binary exporter root must contain only build_output" >&2
    exit 1
  }
fi
[[ -f "$export_dir/$binary_name" && ! -L "$export_dir/$binary_name" ]] || {
  echo "candidate binary exporter did not produce a regular $binary_name executable" >&2
  exit 1
}
actual_entries="$(find "$export_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
[[ "$actual_entries" == "$expected_entries" ]] || {
  printf 'candidate binary exporter layout mismatch for %s\nexpected:\n%s\nactual:\n%s\n' \
    "$component" "$expected_entries" "$actual_entries" >&2
  exit 1
}
while IFS= read -r entry; do
  [[ -f "$export_dir/$entry" && ! -L "$export_dir/$entry" ]] || {
    echo "candidate binary exporter entry is not a regular file: $entry" >&2
    exit 1
  }
done <<<"$expected_entries"

staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT
install -m 0755 "$export_dir/$binary_name" "$staging_dir/$binary_name"

archive_parent="$(dirname "$archive")"
archive_name="$(basename "$archive")"
archive_parent="$(cd "$archive_parent" && pwd)"
(cd "$staging_dir" && zip -X -q "$archive_parent/$archive_name" "$binary_name")

members="$(unzip -Z1 "$archive")"
[[ "$members" == "$binary_name" ]] || {
  echo "candidate binary archive has unexpected members: $members" >&2
  exit 1
}
