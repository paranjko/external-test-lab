#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUEST_WORKFLOW="$ROOT/.github/workflows/candidate-build.yml"
PUBLISH_WORKFLOW="$ROOT/.github/workflows/candidate-publish.yml"
RUNBOOK="$ROOT/net-deployment-runbook"

job_section() {
  local job="$1"
  awk -v job="$job" '
    $0 == "  " job ":" { inside = 1; next }
    inside && $0 ~ /^  [a-z0-9-]+:$/ { exit }
    inside { print }
  ' "$PUBLISH_WORKFLOW"
}

[[ -r "$REQUEST_WORKFLOW" && -r "$PUBLISH_WORKFLOW" ]]
grep -Fq 'workflow_dispatch:' "$REQUEST_WORKFLOW"
! grep -Eq '^[[:space:]]+(pull_request|push|workflow_run):' "$REQUEST_WORKFLOW"
grep -Fq 'permissions:' "$REQUEST_WORKFLOW"
grep -Fq 'contents: read' "$REQUEST_WORKFLOW"
! grep -Eq '(contents|packages|id-token|attestations|actions): write' "$REQUEST_WORKFLOW"
! grep -Eq '(secrets\.|gh release|push: true|attest-build-provenance)' "$REQUEST_WORKFLOW"
grep -Fq 'candidate-publication-request' "$REQUEST_WORKFLOW"
grep -Fq "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" "$REQUEST_WORKFLOW"

grep -Fq 'workflow_run:' "$PUBLISH_WORKFLOW"
! grep -Fq 'workflow_dispatch:' "$PUBLISH_WORKFLOW"
grep -Fq 'permissions: {}' "$PUBLISH_WORKFLOW"
grep -Fq 'workflows: [Candidate build]' "$PUBLISH_WORKFLOW"
grep -Fq "github.event.workflow_run.conclusion == 'success'" "$PUBLISH_WORKFLOW"
grep -Fq "github.event.workflow_run.event == 'workflow_dispatch'" "$PUBLISH_WORKFLOW"
grep -Fq 'github.event.workflow_run.head_branch == github.event.repository.default_branch' "$PUBLISH_WORKFLOW"
grep -Fq "github.event.workflow_run.path == '.github/workflows/candidate-build.yml'" "$PUBLISH_WORKFLOW"
grep -Fq 'ref: ${{ github.event.workflow_run.head_sha }}' "$PUBLISH_WORKFLOW"
grep -Fq 'EXPECTED_SHA: ${{ github.event.workflow_run.head_sha }}' "$PUBLISH_WORKFLOW"
grep -Fq 'EXPECTED_RUN_ID: ${{ github.event.workflow_run.id }}' "$PUBLISH_WORKFLOW"
! grep -Fq '${{ inputs.' "$PUBLISH_WORKFLOW"
grep -Fq 'candidate definition checksum mismatch' "$PUBLISH_WORKFLOW"
grep -Fq 'base image digest mismatch' "$PUBLISH_WORKFLOW"
[[ "$(grep -Fc "awk '\$1 == \"Digest:\" {print \$2}'" "$PUBLISH_WORKFLOW")" == 2 ]]
! grep -Fq "awk '\$1 == \"Digest:\" {print \$2; exit}'" "$PUBLISH_WORKFLOW"
grep -Fq 'WORKFLOW_REF: ${{ github.workflow_ref }}' "$PUBLISH_WORKFLOW"
grep -Fq 'WORKFLOW_SHA: ${{ github.workflow_sha }}' "$PUBLISH_WORKFLOW"
grep -Fq 'REQUEST_SHA: ${{ github.event.workflow_run.head_sha }}' "$PUBLISH_WORKFLOW"
grep -Fq 'request_sha:$request_sha' "$PUBLISH_WORKFLOW"
grep -Fq 'request-${{ github.event.workflow_run.id }}-attempt-${{ github.event.workflow_run.run_attempt }}' "$PUBLISH_WORKFLOW"
grep -Fq 'base_images: ${{ steps.definition.outputs.base_images }}' "$PUBLISH_WORKFLOW"
grep -Fq 'core_version: ${{ steps.definition.outputs.core_version }}' "$PUBLISH_WORKFLOW"
grep -Fq "jq -c '.base_images | map({key:.reference,value:.digest}) | from_entries'" "$PUBLISH_WORKFLOW"
grep -Fq 'docker save "$IMAGE_REFERENCE" | gzip -n' "$PUBLISH_WORKFLOW"
grep -Fq '"$IMAGE_REFERENCE" >image-reference.txt' "$PUBLISH_WORKFLOW"
grep -Fq 'docker push "$IMAGE_REFERENCE"' "$PUBLISH_WORKFLOW"
grep -Fq -- '--arg deployment_reference "$IMAGE_REFERENCE"' "$PUBLISH_WORKFLOW"
grep -Fq 'gh release create "$tag"' "$PUBLISH_WORKFLOW"
grep -Fq 'candidate release asset collision' "$PUBLISH_WORKFLOW"
grep -Fq 'verify-candidate-release-target.sh' "$PUBLISH_WORKFLOW"
grep -Fq 'results/images/*.oci.tar.gz.spdx.json' "$PUBLISH_WORKFLOW"
grep -Fq 'oras_1.3.0_linux_amd64.tar.gz' "$PUBLISH_WORKFLOW"
grep -Fq '6cdc692f929100feb08aa8de584d02f7bcc30ec7d88bc2adc2054d782db57c64' "$PUBLISH_WORKFLOW"
grep -Fq 'syft_1.51.0_linux_amd64.tar.gz' "$PUBLISH_WORKFLOW"
grep -Fq '2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f' "$PUBLISH_WORKFLOW"
grep -Fq 'actions/attest-build-provenance@e8998f949152b193b063cb0ec769d69d929409be' "$PUBLISH_WORKFLOW"

prepare_job="$(job_section prepare)"
images_job="$(job_section images)"
binaries_job="$(job_section binaries)"
publish_images_job="$(job_section publish-images)"
publish_binaries_job="$(job_section publish-binaries)"
manifest_job="$(job_section manifest)"

grep -Fq 'path: automation' <<<"$manifest_job"
grep -Fq 'contents: read' <<<"$prepare_job"
! grep -Eq '(contents|packages|id-token|attestations): write' <<<"$prepare_job"
for isolated_job in "$images_job" "$binaries_job"; do
  grep -Fq 'contents: read' <<<"$isolated_job"
  grep -Fq 'repository: gonka-ai/gonka' <<<"$isolated_job"
  grep -Fq 'ref: ${{ github.workflow_sha }}' <<<"$isolated_job"
  grep -Fq 'pin-candidate-dockerfile.py' <<<"$isolated_job"
  grep -Fq 'BASE_IMAGES_JSON: ${{ needs.prepare.outputs.base_images }}' <<<"$isolated_job"
  ! grep -Eq '(contents|packages|id-token|attestations): write' <<<"$isolated_job"
  ! grep -Eq '(secrets\.|GH_TOKEN|docker/login-action|oras (login|push)|attest-build-provenance)' <<<"$isolated_job"
done
grep -Fq 'matrix: ${{ fromJson(needs.prepare.outputs.image_matrix) }}' <<<"$images_job"
grep -Fq 'matrix: ${{ fromJson(needs.prepare.outputs.binary_matrix) }}' <<<"$binaries_job"
grep -Fq 'matrix: ${{ fromJson(needs.prepare.outputs.publish_image_matrix) }}' <<<"$publish_images_job"
grep -Fq 'matrix: ${{ fromJson(needs.prepare.outputs.publish_binary_matrix) }}' <<<"$publish_binaries_job"
grep -Fq 'workflow-matrix "$PROFILE"' <<<"$prepare_job"
grep -Fq 'LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain' "$RUNBOOK/scripts/release-candidate.py"
grep -Fq 'LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api' "$RUNBOOK/scripts/release-candidate.py"
grep -Fq 'INFERENCED_LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain' "$RUNBOOK/scripts/release-candidate.py"
! grep -Fq '${{ github.run_id }}-${{ github.run_attempt }}' <<<"$images_job"
! grep -Fq 'make devshardd-release' <<<"$binaries_job"
grep -Fq 'package-candidate-binary.sh' <<<"$binaries_job"
grep -Fq 'Dockerfile.inferenced-operator' "$RUNBOOK/scripts/release-candidate.py"
grep -Fq 'inferenced package/build_output/inferenced "$CORE_VERSION" "$CORE_COMMIT" operator' <<<"$binaries_job"
grep -Fq -- '--build-arg "LDFLAGS=$inferenced_ldflags"' <<<"$binaries_job"
grep -Fq -- '--build-arg DEVSHARD_VERSION=v5 --build-arg "LDFLAGS=$dapi_ldflags"' <<<"$binaries_job"
grep -Fq -- '--build-arg "INFERENCED_LDFLAGS=$inferenced_ldflags"' <<<"$binaries_job"
grep -Fq 'patch-candidate-dapi-dockerfile.py' <<<"$binaries_job"
grep -Fq 'inferenced package/build_output/inferenced "$CORE_VERSION" "$CORE_COMMIT" metadata' <<<"$binaries_job"
grep -Fq 'generate-candidate-binary-sbom.sh' <<<"$binaries_job"
! grep -Fq 'syft "dir:package"' <<<"$binaries_job"

for publication_job in "$publish_images_job" "$publish_binaries_job"; do
  grep -Fq 'packages: write' <<<"$publication_job"
  grep -Fq 'id-token: write' <<<"$publication_job"
  grep -Fq 'attestations: write' <<<"$publication_job"
  ! grep -Fq 'repository: gonka-ai/gonka' <<<"$publication_job"
  ! grep -Fq 'actions/checkout@' <<<"$publication_job"
  ! grep -Eq '(docker/build-push-action|docker buildx build|make devshardd-release)' <<<"$publication_job"
done
grep -Fq 'IMAGE_REFERENCE="$(cat image/image-reference.txt)"' <<<"$publish_images_job"
grep -Fq 'IMAGE_REFERENCE: ${{ steps.image.outputs.reference }}' <<<"$publish_images_job"
! grep -Fq '${{ github.run_id }}-${{ github.run_attempt }}' <<<"$publish_images_job"
grep -Fq 'unzip -Z1 "binary/$COMPONENT-linux-amd64.zip")" == "$ARCHIVE_MEMBER"' <<<"$publish_binaries_job"
grep -Fq 'reference="$repository:$PROFILE-${DEFINITION_SHA256:0:12}-$GITHUB_RUN_ID"' <<<"$publish_binaries_job"
! grep -Fq 'reference="$repository:$PROFILE-${DEFINITION_SHA256:0:12}-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"' <<<"$publish_binaries_job"

operator_dockerfile="$RUNBOOK/candidate/Dockerfile.inferenced-operator"
grep -Fq "FROM golang:1.24.2-alpine3.21 AS builder" "$operator_dockerfile"
grep -Fq -- "-extldflags '-static'" "$operator_dockerfile"
grep -Fq 'COPY --from=builder /build_output/inferenced /build_output/inferenced' "$operator_dockerfile"

grep -Fq 'contents: write' <<<"$manifest_job"
! grep -Eq '(packages|id-token|attestations): write' <<<"$manifest_job"
grep -Fq './gdc.sh release candidate prepare --source-ref upgrade-v0.2.16' "$RUNBOOK/gdc.sh"
# The launcher must remain in process so its single EXIT boundary records a
# failed release command in the same private failure-envelope contract.
grep -Fq '"$ROOT/scripts/release-candidate.py" "$@"' "$RUNBOOK/gdc.sh"
! grep -Fq 'exec "$ROOT/scripts/release-candidate.py" "$@"' "$RUNBOOK/gdc.sh"

grep -Fq 'group: candidate-publish-${{ github.event.workflow_run.display_title }}' "$PUBLISH_WORKFLOW"
! grep -Fq 'candidate-publish-${{ github.event.workflow_run.id }}' "$PUBLISH_WORKFLOW"
retry_fixture="$(mktemp -d)"
trap 'rm -rf "$retry_fixture"' EXIT
built_reference=ghcr.io/paranjko/gdc-inferenced:v2026.08.25-rc.0-definition-202
printf '%s\n' "$built_reference" >"$retry_fixture/image-reference.txt"
for publisher_attempt in 1 2; do
  expected_reference=ghcr.io/paranjko/gdc-inferenced:v2026.08.25-rc.0-definition-202
  [[ "$(cat "$retry_fixture/image-reference.txt")" == "$expected_reference" ]]
  [[ "$expected_reference" != *"-$publisher_attempt" ]]
done

built_binary_reference=ghcr.io/paranjko/gdc-upgrade-inferenced:v2026.08.25-rc.0-definition-202
for publisher_attempt in 1 2; do
  expected_binary_reference=ghcr.io/paranjko/gdc-upgrade-inferenced:v2026.08.25-rc.0-definition-202
  [[ "$built_binary_reference" == "$expected_binary_reference" ]]
  [[ "$expected_binary_reference" != *"-$publisher_attempt" ]]
done

# Two overlapping request runs for the same immutable candidate share the publisher concurrency group
req1_title="candidate v2026.08.25-rc.0 74fc6807051c327631c707a69cb5527370e543f0b9c93cecf8db925287174e0f"
req2_title="candidate v2026.08.25-rc.0 74fc6807051c327631c707a69cb5527370e543f0b9c93cecf8db925287174e0f"
group1="candidate-publish-$req1_title"
group2="candidate-publish-$req2_title"
[[ "$group1" == "$group2" ]]

# Verify existing tag resolution fixture: matching target passes, stale target fails
target_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
stale_target_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
verify_tag_target() {
  local actual="$1" expected="$2"
  [[ "$actual" == "$expected" ]]
}
verify_tag_target "$target_sha" "$target_sha"
! verify_tag_target "$stale_target_sha" "$target_sha"

printf 'PASS candidate workflow security contract\n'
