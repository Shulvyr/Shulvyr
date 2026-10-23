"""Check committed oracle bytes and their generator against the manifest."""

import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/foundation/fixtures/nbt"
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest["schema"] != 2:
        raise ValueError("Unsupported fixture manifest schema")
    sources = manifest["sources"]
    if set(sources) != {"NBT", "BinaryUtils", "BedrockProtocol"}:
        raise ValueError("Unexpected oracle source set")
    for source in sources.values():
        if set(source) != {"repository", "branch", "revision"}:
            raise ValueError("Oracle sources must record repository, branch and revision")
        if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", source["repository"]):
            raise ValueError("Invalid oracle repository URL")
        if not source["branch"] or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
            raise ValueError("Oracle sources require a branch and exact Git commit")
    expected = {
        f"{case}.{variant}.nbt"
        for case in ("all-tags", "scalar", "nested-lists", "sequence")
        for variant in ("big", "little", "network")
    }
    if set(manifest["files"]) != expected:
        raise ValueError("Unexpected fixture manifest file set")
    if {path.name for path in directory.glob("*.nbt")} != expected:
        raise ValueError("Fixture directory differs from manifest")
    generator = root / "tools/generate_nbt_fixtures.php"
    if hashlib.sha256(generator.read_bytes()).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Oracle generator changed without regenerating fixtures")
    for name, metadata in manifest["files"].items():
        data = (directory / name).read_bytes()
        if len(data) != metadata["bytes"]:
            raise ValueError(f"Fixture size mismatch: {name}")
        if hashlib.sha256(data).hexdigest() != metadata["sha256"]:
            raise ValueError(f"Fixture SHA-256 mismatch: {name}")
    print(f"Verified {len(expected)} NBT fixtures and oracle generator")


if __name__ == "__main__":
    main()
