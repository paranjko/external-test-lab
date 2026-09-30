#!/usr/bin/env python3
"""Reproducible local Perfetto build, full WASM and dist, no runtime downloads."""
import hashlib
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "perfetto-build.json").read_text())
source = root / ".cache/perfetto"
parser = argparse.ArgumentParser()
parser.add_argument("--prepare-only", action="store_true", help="refresh integration sources without starting another build")
parser.add_argument("--package-only", action="store_true", help="package an already completed matching UI build")
args = parser.parse_args()

def run(*args, cwd=source):
    subprocess.run(args, cwd=cwd, check=True)

if not source.exists():
    source.parent.mkdir(exist_ok=True)
    run("git", "clone", "--filter=blob:none", "--no-checkout", manifest["repository"], str(source), cwd=root)
    run("git", "checkout", "--detach", manifest["sha"])
if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() != manifest["sha"]:
    raise SystemExit("Perfetto checkout is not pinned SHA; preserve it and use the correct source")
plugin = source / "ui/src/plugins/net.gonka.Consensus"
plugin.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "ui/net.gonka.Consensus/index.ts", plugin / "index.ts")
shutil.copy2(root / "ui/net.gonka.Consensus/epoch_bands.ts", plugin / "epoch_bands.ts")
shutil.copy2(root / "ui/net.gonka.Consensus/participants.ts", plugin / "participants.ts")
embedder = source / "ui/src/core/embedder"
shutil.copy2(root / "ui/gonka_embedder.ts", embedder / "gonka_embedder.ts")
(embedder / "create_embedder.ts").write_text("import {GonkaEmbedder} from './gonka_embedder';\nexport function createEmbedder() { return new GonkaEmbedder(); }\n")
frontend = source / "ui/src/frontend/index.ts"
text = frontend.read_text()
text = text.replace("AppImpl.instance.serviceWorkerController.install();", "// Gonka offline bundle: no service worker registration")
text = text.replace("import {checkHttpRpcConnection} from './rpc_http_dialog';", "")
text = text.replace("checkHttpRpcConnection().then(() => {", "Promise.resolve().then(() => {")
frontend.write_text(text)
app = source / "ui/src/core/app_impl.ts"
app.write_text(app.read_text().replace("newEngineMode: 'USE_HTTP_RPC_IF_AVAILABLE' as NewEngineMode", "newEngineMode: 'FORCE_BUILTIN_WASM' as NewEngineMode"))
extensions = source / "ui/src/core_plugins/dev.perfetto.ExtensionServers/index.ts"
extension_text = extensions.read_text()
guard = "    if (ctx.embedder.extensionServer === undefined) return;"
if guard not in extension_text:
    extension_text = extension_text.replace("  static onActivate(ctx: AppImpl, args: RouteArgs) {", "  static onActivate(ctx: AppImpl, args: RouteArgs) {\n" + guard)
extensions.write_text(extension_text)
builder = source / "ui/build.mjs"
build_text = builder.read_text().replace("const ninjaArgs = ['-C', cfg.outDir];", "const ninjaArgs = ['-C', cfg.outDir, '-j', '6'];").replace("const ninjaArgs = ['-C', cfg.outDir, '-j', '2'];", "const ninjaArgs = ['-C', cfg.outDir, '-j', '6'];")
builder.write_text(build_text)
if args.prepare_only:
    raise SystemExit(0)
if not args.package_only and os.environ.get("GONKA_PERFETTO_DEPS_READY") != "1":
    run("tools/install-build-deps", "--ui")
if not args.package_only:
    run("ui/build")
dist = source / "ui/out/dist"
destination = root / "ui-dist"
shutil.copytree(dist, destination, dirs_exist_ok=True)
for css in destination.rglob("*.css"):
    css.write_text(re.sub(r"(?:\.\./)+assets/assets/", "assets/", css.read_text()))
notices = destination / "licenses"
notices.mkdir(exist_ok=True)
for name in ("LICENSE", "NOTICE"):
    if (source / name).is_file():
        shutil.copy2(source / name, notices / name)
# Preserve notices from the source/dependency distribution as well as Perfetto's
# own license. This deliberately includes build-time packages, not only a guessed
# subset of minified runtime imports.
for folder in (source / "third_party", source / "buildtools", source / "ui/node_modules"):
    for path in folder.rglob("*"):
        if path.is_file() and path.name.upper().split(".")[0] in ("LICENSE", "NOTICE", "COPYING", "COPYRIGHT"):
            target = notices / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
files = []
for path in sorted(destination.rglob("*")):
    if path.is_file() and path.name != "asset-manifest.json":
        files.append({"path": str(path.relative_to(destination)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size})
if not any(f["path"].endswith(".wasm") for f in files):
    raise SystemExit("No WASM in dist; release refused")
integration = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (root / "ui/net.gonka.Consensus/index.ts", root / "ui/net.gonka.Consensus/epoch_bands.ts", root / "ui/net.gonka.Consensus/participants.ts", root / "ui/gonka_embedder.ts", root / "ui/build_perfetto.py")}
(destination / "asset-manifest.json").write_text(json.dumps({"build": manifest, "integration": integration, "files": files}, indent=2) + "\n")
print(f"Verified complete dist: {len(files)} assets")
