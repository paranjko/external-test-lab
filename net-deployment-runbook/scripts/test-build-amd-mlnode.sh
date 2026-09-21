#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$ROOT/profiles/amd-mlnode/gfx1201.json"
script="$ROOT/scripts/build-amd-mlnode.sh"

python3 "$ROOT/images/test-adapt-mlnode-rocm-runner.py"

jq -e '
  .sources.gonka.commit == "4d687ed6782bcea3931d2d9135bf322f84e190ab" and
  .sources.gonka.submodules.gorilla == {path:"mlnode/packages/train/third_party/gorilla", commit:"d8fc7e364de491984466e2ce776a2e13b0ae2fe0"} and
  .sources.vllm.commit == "052648bf42ab2e9db7c163b8f1909eb6ea41d86b" and
  .accelerator.vendor == "amd" and .accelerator.architecture == "gfx1201" and
  .accelerator.pci_device_ids == ["0x7550"] and
  .host_provisioning.ubuntu_version_id == "24.04" and
  .attention_backend == "ROCM_ATTN" and
  (.host_provisioning.installer_sha256 | test("^[0-9a-f]{64}$")) and
  (.host_provisioning.installer_package_version | test("^[0-9]")) and
  (.base_image | test("@sha256:[0-9a-f]{64}$")) and
  (.output_image | startswith("ghcr.io/paranjko/gdc-mlnode:")) and
  .output_image == "ghcr.io/paranjko/gdc-mlnode:3.0.14-rocm-gfx1201-rocm-cli-4d687ed-052648b" and
  (.published_image | test("^ghcr.io/paranjko/gdc-mlnode:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$"))
' "$profile" >/dev/null

plan="$($script "$profile" --plan)"
grep -Fq 'PLAN source.gonka=https://github.com/gonka-ai/gonka.git@4d687ed6782bcea3931d2d9135bf322f84e190ab' <<<"$plan"
grep -Fq 'PLAN source.gonka.submodule=mlnode/packages/train/third_party/gorilla@d8fc7e364de491984466e2ce776a2e13b0ae2fe0' <<<"$plan"
grep -Fq 'berkeley-function-call-leaderboard/pyproject.toml' "$script"
grep -Fq 'PLAN source.vllm=https://github.com/gonka-ai/vllm.git@052648bf42ab2e9db7c163b8f1909eb6ea41d86b' <<<"$plan"
grep -Fq 'PLAN attention_backend=ROCM_ATTN' <<<"$plan"
grep -Fq 'PLAN output=ghcr.io/paranjko/gdc-mlnode:3.0.14-rocm-gfx1201-rocm-cli-4d687ed-052648b' <<<"$plan"
grep -Fq 'ARG_PYTORCH_ROCM_ARCH=gfx1201' "$script"
grep -Fq -- '--device /dev/kfd' "$script"
grep -Fq 'torch.version.hip' "$script"
grep -Fq -- '--ci-publish is reserved for GitHub Actions' "$script"
grep -Fq 'docker push "$output_image"' "$script"
grep -Fq 'org.opencontainers.image.source=$artifact_repository' "$script"
grep -Fq 'io.gonka.upstream.revision=$gonka_commit' "$script"
expected_base="$(printf 'FROM $%s' '{VLLM_BASE_IMAGE}')"
grep -Fq "$expected_base" "$ROOT/images/Dockerfile.mlnode-rocm"
grep -Fq 'python3 -m venv --system-site-packages /app/packages/api/.venv' "$ROOT/images/Dockerfile.mlnode-rocm"
if grep -Fq 'VLLM_ATTENTION_BACKEND' "$ROOT/images/Dockerfile.mlnode-rocm"; then exit 1; fi
grep -Fq 'adapt-mlnode-rocm-runner.py' "$script"
grep -Fq 'check-mlnode-rocm-runner.py' "$script"
grep -Fq 'check-mlnode-rocm-runner.py' "$ROOT/images/Dockerfile.mlnode-rocm"
if grep -Fq 'flash-attn' "$ROOT/images/Dockerfile.mlnode-rocm"; then exit 1; fi
if grep -Fq 'TRITON_PTXAS_PATH' "$ROOT/images/Dockerfile.mlnode-rocm"; then exit 1; fi
printf 'PASS AMD MLNode build profile and ROCm adapter contract\n'
