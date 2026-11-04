#!/usr/bin/env python3
"""Build a Codex marketplace archive from this repository's plugin sources."""

import argparse
import gzip
import io
import json
from pathlib import Path
import tarfile


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = Path("plugins/axonflow")
CONTENT = (
    Path(".codex-plugin/plugin.json"),
    Path(".mcp.json"),
    Path("CHANGELOG.md"),
    Path("LICENSE"),
    Path("README.md"),
    Path("assets"),
    Path("hooks"),
    Path("scripts"),
    Path("skills"),
)


def add_bytes(tar: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = 0
    tar.addfile(info, io.BytesIO(data))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="output .tar.gz path")
    args = parser.parse_args()

    legacy = json.loads((ROOT / ".codex-plugin/marketplace.json").read_text())
    plugin = dict(legacy["plugins"][0])
    plugin["source"] = {"source": "local", "path": "./plugins/axonflow"}
    plugin["category"] = "Productivity"
    plugin["policy"] = {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}
    manifest = {**legacy, "plugins": [plugin]}
    metadata = json.loads((ROOT / ".codex-plugin/plugin.json").read_text())
    if metadata["version"] != plugin["version"] or metadata["name"] != plugin["name"]:
        raise ValueError("marketplace and plugin metadata disagree")

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.is_relative_to(ROOT):
        raise ValueError("write the release archive outside the source tree")
    with output.open("wb") as target, gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w") as tar:
            add_bytes(tar, ".agents/plugins/marketplace.json", (json.dumps(manifest, indent=2) + "\n").encode())
            add_bytes(tar, "INSTALL.md", (
                "# AxonFlow Codex marketplace\n\n"
                "Extract this archive to an empty directory, then run:\n\n"
                "```sh\n"
                "codex plugin marketplace add /absolute/path/to/extracted-directory\n"
                "codex plugin list --marketplace axonflow\n"
                "codex plugin add axonflow@axonflow\n"
                "```\n\n"
                "Follow `plugins/axonflow/README.md` for Hosted linking or self-hosted setup.\n"
            ).encode())
            for entry in CONTENT:
                source = ROOT / entry
                files = sorted(source.rglob("*")) if source.is_dir() else [source]
                for file in files:
                    if not file.is_file():
                        continue
                    if file.is_symlink() or any(part in {"__pycache__", ".DS_Store"} for part in file.parts):
                        raise ValueError(f"unexpected package entry: {file}")
                    relative = file.relative_to(ROOT)
                    add_bytes(tar, str(PLUGIN / relative), file.read_bytes(), file.stat().st_mode & 0o777)
    print(output)


if __name__ == "__main__":
    main()
