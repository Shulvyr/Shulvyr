"""Verify committed math oracle bytes and their generator."""

import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/math/fixtures"
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest["schema"] != 1 or set(manifest["files"]) != {"conformance.json"}:
        raise ValueError("Unsupported math fixture manifest")
    oracle = manifest["oracle"]
    if oracle["repository"] != "https://github.com/pmmp/Math" or oracle["branch"] != "stable":
        raise ValueError("Unexpected math oracle source")
    if not re.fullmatch(r"[0-9a-f]{40}", oracle["revision"]):
        raise ValueError("Math oracle requires an exact Git revision")
    generator = root / "tools/generate_math_fixtures.php"
    if hashlib.sha256(generator.read_bytes()).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Math generator changed without regenerating fixtures")
    data = (directory / "conformance.json").read_bytes()
    expected = manifest["files"]["conformance.json"]
    if len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
        raise ValueError("Math fixture bytes differ from manifest")
    cases = json.loads(data)
    print(f"Verified {sum(len(group) for group in cases.values())} math oracle cases")


if __name__ == "__main__":
    main()
