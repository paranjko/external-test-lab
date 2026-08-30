#!/usr/bin/env bash
set -Eeuo pipefail

printf '%q ' "$@" >>"$GDC_TEST_DOCKER_LOG"
printf '\n' >>"$GDC_TEST_DOCKER_LOG"
case "${1:-} ${2:-}" in
  'ps -aq')
    [[ ${GDC_TEST_DOCKER_PS_FAIL:-false} != true ]] || exit 73
    [[ ! -e "$GDC_TEST_CONTAINER_PRESENT" ]] || printf '%s\n' legacy-admission
    ;;
  'rm -f')
    shift 2
    [[ "$*" == legacy-admission ]]
    rm -f "$GDC_TEST_CONTAINER_PRESENT"
    ;;
  *)
    exit 2
    ;;
esac
