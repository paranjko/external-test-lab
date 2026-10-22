# The GDC adapter supports the upstream single-Host CUDA recipe, not arbitrary
# remote programs. Unknown recipes/services fail before provisioning a Host.
.software as $s |
($s.platform == "linux/amd64" and $s.accelerator == "cuda") and
($s.model |
  if .id == "Qwen/Qwen3-0.6B" then
    .revision == "c1899de289a04d12100db370d81485cdf75e47ca" and
    .context_length == 2048 and .dtype == "auto" and .tensor_parallel_size == 1 and
    ((.max_num_seqs == 64 and .gpu_memory_utilization == 0.85) or
     (.max_num_seqs == 32 and .gpu_memory_utilization == 0.45))
  elif .id == "Qwen/Qwen2.5-7B-Instruct" then
    .revision == "a09a35458c702b33eeacc393d103063234e8bc28" and
    .context_length == 4096 and .max_num_seqs == 32 and
    .gpu_memory_utilization == 0.92 and .dtype == "bfloat16" and .tensor_parallel_size == 1
  elif .id == "Qwen/Qwen3-4B-Instruct-2507" then
    .revision == "cdbee75f17c01a7cc42f958dc650907174af0554" and
    .context_length == 25000 and .max_num_seqs == 1 and
    .gpu_memory_utilization == 0.85 and .dtype == "bfloat16" and .tensor_parallel_size == 1
  else false end) and
($s.deployment.repository == "https://github.com/gonka-ai/gonka.git") and
($s.deployment.compose_files | sort_by(.path)) == ([
  {path:"deploy/join/docker-compose.yml",sha256:"b8fcd8d3538b6c14f882d33aa8d82b835c91904b1894cb50a5346ded6e2e45bc"},
  {path:"deploy/join/docker-compose.mlnode.yml",sha256:"6ec6da9a56c737ab8f49e66af2325220319f987134aba0eadc7b673d532bd51d"}
] | sort_by(.path)) and
($s.components | keys) == (["node","api","tmkms","mlnode","payload-postgres","edge-api","versiond","versiond-router","proxy","proxy-policy","explorer","inference-proxy","caddy","grafana","node-exporter","cadvisor","bridge"] | sort) and
($s.components | all(to_entries[];
  (.value.version | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")) and
  (.value.image | type == "string" and test("^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$")))) and
($s.operator_cli.artifact.executable == "inferenced") and
($s.components.node.upgrade.artifact.executable == "inferenced") and
($s.components.api.upgrade.artifact.executable == "decentralized-api") and
($s.components.node.commit | type == "string" and test("^[a-f0-9]{40}$")) and
($s.components.api.commit | type == "string" and test("^[a-f0-9]{40}$"))
