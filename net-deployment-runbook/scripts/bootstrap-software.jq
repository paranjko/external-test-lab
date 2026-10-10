# Operator-side validation of the embedded software v1 contract (no Python).
# Keep conformance with schema/v1.bootstrap.schema.json covered by tests.
def shape($required; $optional):
  type == "object" and
  (($required - keys) | length == 0) and
  ((keys - ($required + $optional)) | length == 0);
def matches($pattern): type == "string" and test($pattern);
def digest: matches("^[0-9a-f]{64}$");
def path: matches("^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$");
def url: matches("^https://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?(/[A-Za-z0-9._~/%:-]*)?$");
def version: matches("^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$");
def positive_integer: type == "number" and . > 0 and floor == .;
def artifact:
  shape(["url","sha256","format","executable"]; []) and
  (.url | url) and (.sha256 | digest) and .format == "zip" and (.executable | path);
def component($runtime):
  shape(["version","image"]; if $runtime then ["upgrade","commit"] else [] end) and
  (if has("commit") then (.commit | matches("^[0-9a-f]{40}$")) else true end) and
  (.version | version) and
  (.image | matches("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$")) and
  (if has("upgrade") then
    (.upgrade | shape(["name","artifact"]; []) and
      (.name | matches("^[A-Za-z0-9_-][A-Za-z0-9._-]*$")) and (.artifact | artifact))
   else true end);
.software |
shape(["schema_version","platform","accelerator","deployment","components","operator_cli","model"]; []) and
.schema_version == 1 and
(.platform == "linux/amd64" or .platform == "linux/arm64") and
(.accelerator == "cuda" or .accelerator == "rocm" or .accelerator == "cpu") and
(.deployment |
  shape(["repository","commit","compose_files"]; []) and
  (.repository | url) and (.commit | matches("^[0-9a-f]{40}$")) and
  (.compose_files | type == "array" and length > 0 and
    all(.[]; shape(["path","sha256"]; []) and (.path | path) and (.sha256 | digest)) and
    ([.[].path] | length == (unique | length)))) and
(.components |
  type == "object" and has("node") and has("api") and has("tmkms") and has("mlnode") and
  all(to_entries[]; (.key | matches("^[a-z][a-z0-9_-]*$")) and
    ((.key == "node" or .key == "api") as $runtime | .value | component($runtime)))) and
(.operator_cli | shape(["version","artifact"]; []) and (.version | version) and (.artifact | artifact)) and
(.operator_cli.version == .components.node.version) and
(.model |
  shape(["id","revision","context_length","max_num_seqs","gpu_memory_utilization","dtype","tensor_parallel_size"]; []) and
  (.id | matches("^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  (.revision | matches("^[0-9a-f]{40}$")) and
  (.context_length | positive_integer) and (.max_num_seqs | positive_integer) and
  (.gpu_memory_utilization | type == "number" and . > 0 and . <= 1) and
  (.dtype == "auto" or .dtype == "float16" or .dtype == "bfloat16" or .dtype == "float32") and
  (.tensor_parallel_size | positive_integer))
