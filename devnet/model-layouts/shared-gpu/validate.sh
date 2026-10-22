#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -f $1 && ! -L $1 ]] || {
  echo 'Usage: validate.sh DESCRIPTOR.json' >&2
  exit 2
}
jq -e '
  def pinned: type == "string" and test("^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$");
  def model:
    (type == "object" and
     (keys|sort)==["args","image","inference_port","management_port","model_id","revision"] and
     (.model_id|type=="string" and length>0) and
     (.revision|type=="string" and length>0) and
     (.image|pinned) and
     (.args|type=="array" and all(.[]; type=="string")) and
     (.management_port|type=="number" and floor==. and .>0 and .<65536) and
     (.inference_port|type=="number" and floor==. and .>0 and .<65536));
  def revision_matches:
    . as $w | ($w.args|index("--revision")) as $i |
    $i != null and $i+1 < ($w.args|length) and $w.args[$i+1] == $w.revision;
  def valid_utilization:
    . as $w | ($w.args|index("--gpu-memory-utilization")) as $i |
    $i != null and $i+1 < ($w.args|length) and
    ($w.args[$i+1]|try tonumber catch -1) > 0 and
    ($w.args[$i+1]|try tonumber catch 2) <= 1;
  type=="object" and
  (keys|sort)==["gpu_device","hf_cache_root","host_docker_network","nginx_image","primary","secondary"] and
  (.gpu_device|type=="string" and test("^[0-9]+$")) and
  (.host_docker_network|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
  (.hf_cache_root|type=="string" and startswith("/") and (contains("..")|not)) and
  (.nginx_image|pinned) and
  (.primary|model and revision_matches and valid_utilization) and
  (.secondary|model and revision_matches and valid_utilization) and
  (.primary.model_id != .secondary.model_id) and
  (.primary.management_port==8080 and .primary.inference_port==5000 and
   .secondary.management_port==8080 and .secondary.inference_port==5000)
' "$1" >/dev/null || {
  echo 'Invalid shared-GPU descriptor: require pinned images, model revisions, revision args, GPU device and utilization in (0,1]' >&2
  exit 1
}
