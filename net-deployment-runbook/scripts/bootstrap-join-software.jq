# The GDC adapter supports the upstream single-Host CUDA recipe, not arbitrary
# remote programs. Unknown recipes/services fail before provisioning a Host.
.software as $s |
($s.platform == "linux/amd64" and $s.accelerator == "cuda") and
($s.model.id == "Qwen/Qwen3-0.6B") and
($s.deployment.repository == "https://github.com/gonka-ai/gonka.git") and
($s.deployment.compose_files | sort_by(.path)) == ([
  {path:"deploy/join/docker-compose.yml",sha256:"b8fcd8d3538b6c14f882d33aa8d82b835c91904b1894cb50a5346ded6e2e45bc"},
  {path:"deploy/join/docker-compose.mlnode.yml",sha256:"6ec6da9a56c737ab8f49e66af2325220319f987134aba0eadc7b673d532bd51d"}
] | sort_by(.path)) and
($s.components | keys) == (["node","api","tmkms","mlnode","payload-postgres","edge-api","versiond","versiond-router","proxy","proxy-policy","explorer","inference-proxy","caddy","grafana","node-exporter","cadvisor","bridge"] | sort) and
($s.operator_cli.artifact.executable == "inferenced") and
($s.components.node.upgrade.artifact.executable == "inferenced") and
($s.components.api.upgrade.artifact.executable == "decentralized-api") and
($s.components.node.commit | type == "string" and test("^[a-f0-9]{40}$")) and
($s.components.api.commit | type == "string" and test("^[a-f0-9]{40}$"))
