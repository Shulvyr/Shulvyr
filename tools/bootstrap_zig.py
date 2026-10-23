"""Install the pinned development compiler from a verified official archive."""

import argparse
import hashlib
import json
import os
import platform
import subprocess
import tarfile
import urllib.request
import zipfile
from pathlib import Path


def install(output: Path) -> Path:
    repository = Path(__file__).resolve().parents[1]
    version = (repository / ".zigversion").read_text(encoding="utf-8").strip()
    manifest = json.loads((repository / "tools" / "zig-downloads.json").read_text(encoding="utf-8"))
    if version != manifest["version"]:
        raise ValueError("Compiler version and download manifest disagree")
    machine = platform.machine().lower()
    if machine not in ("amd64", "x86_64"):
        raise ValueError("Bootstrap currently supports x86_64 hosts")
    system = platform.system().lower()
    entry = manifest[f"x86_64-{system}"]
    folder = f"zig-x86_64-{system}-{version}"
    suffix = ".zip" if system == "windows" else ".tar.xz"
    expected_url = f"https://ziglang.org/download/{version}/{folder}{suffix}"
    if entry["url"] != expected_url:
        raise ValueError("Unexpected compiler download URL")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{folder}{suffix}"
    if archive.is_symlink():
        raise ValueError("Compiler archive must not be a symbolic link")
    if not archive.exists():
        with urllib.request.urlopen(expected_url, timeout=60) as response:
            with archive.open("xb") as destination:
                received = 0
                while chunk := response.read(1024 * 1024):
                    received += len(chunk)
                    if received > entry["size"]:
                        raise ValueError("Compiler download exceeds its pinned size")
                    destination.write(chunk)
    if archive.stat().st_size != entry["size"]:
        raise ValueError("Incomplete compiler archive, remove it before retrying")
    with archive.open("rb") as source:
        actual_hash = hashlib.file_digest(source, "sha256").hexdigest()
    if actual_hash != entry["sha256"]:
        raise ValueError("Compiler archive checksum mismatch")

    def check_path(name: str) -> None:
        relative = Path(name)
        if not relative.parts or relative.parts[0] != folder:
            raise ValueError("Unexpected compiler archive root")
        if not (output / relative).resolve().is_relative_to(output / folder):
            raise ValueError("Compiler archive path escapes its destination")

    if suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                check_path(item.filename)
            source.extractall(output)
    else:
        with tarfile.open(archive, "r:xz") as source:
            for item in source.getmembers():
                check_path(item.name)
            source.extractall(output, filter="data")
    compiler = output / folder / ("zig.exe" if system == "windows" else "zig")
    detected = subprocess.check_output([str(compiler), "version"], text=True).strip()
    if detected != version:
        raise ValueError("Installed compiler reports an unexpected version")
    return compiler


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("work/toolchains"))
    parser.add_argument("--github-path", action="store_true")
    arguments = parser.parse_args()
    executable = install(arguments.output_dir)
    if arguments.github_path:
        with Path(os.environ["GITHUB_PATH"]).open("a", encoding="utf-8") as destination:
            destination.write(f"{executable.parent}\n")
    print(executable)
