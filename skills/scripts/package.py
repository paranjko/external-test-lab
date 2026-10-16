"""Build the diagnosis skill's deterministic, allowlisted release package."""

import argparse
import hashlib
from pathlib import Path
import zipfile

FILES = (
    "LICENSE.txt",
    "README.md",
    "SKILL.md",
    "agents/openai.yaml",
    "references/trace-collection.md",
)


def package(source, destination):
    payload = {}
    for name in FILES:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected regular package file: {name}")
        payload[name] = path.read_bytes()
    payload["SHA256SUMS"] = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n"
        for name, data in sorted(payload.items())
    ).encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(payload.items()):
            entry = zipfile.ZipInfo(f"gonka-validator-diagnosis/{name}", (2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".zip.sha256").write_text(f"{digest}  {destination.name}\n")
    print(f"{digest}  {destination.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(Path(__file__).resolve().parents[1] / "gonka-validator-diagnosis", args.output)
