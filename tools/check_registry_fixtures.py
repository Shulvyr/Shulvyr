"""Verify registry oracle inputs, outputs, sources and complete mapping hash."""

import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/registry/fixtures"
    manifest = json.loads((directory / "manifest.json").read_bytes())
    if manifest["schema"] != 1 or set(manifest["files"]) != {"input.json", "expected.json"}:
        raise ValueError("Unsupported registry fixture manifest")
    expected_oracles = {
        "NBT": ("https://github.com/pmmp/NBT", "stable"),
        "BedrockProtocol": ("https://github.com/axolotl-pm/BedrockProtocol", "master"),
    }
    if set(manifest["oracles"]) != set(expected_oracles):
        raise ValueError("Unexpected registry oracles")
    for name, (repository, branch) in expected_oracles.items():
        source = manifest["oracles"][name]
        if source["repository"] != repository or source["branch"] != branch or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
            raise ValueError("Registry oracle needs its source revision")
    generator = root / "tools/generate_registry_fixtures.php"
    if hashlib.sha256(generator.read_bytes()).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Registry oracle generator changed without regeneration")
    for name, expected in manifest["files"].items():
        data = (directory / name).read_bytes()
        if expected != {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}:
            raise ValueError(f"Registry fixture hash mismatch: {name}")
    data_manifest = json.loads((root / "data/bedrock/manifest.json").read_bytes())
    if manifest["data_source"] != data_manifest["source"]:
        raise ValueError("Registry fixture uses a different data snapshot")
    item_bytes = (root / "data/bedrock/required_item_list.json").read_bytes()
    if hashlib.sha256(item_bytes).hexdigest() != manifest["data_sha256"]:
        raise ValueError("Registry oracle data changed")
    items = json.loads(item_bytes)
    expected = json.loads((directory / "expected.json").read_bytes())
    mapping = "".join(f"{key}\t{value['runtime_id']}\n" for key, value in sorted(items.items())).encode("ascii")
    if expected["source_entry_count"] != len(items) or expected["source_mapping_sha256"] != hashlib.sha256(mapping).hexdigest():
        raise ValueError("Complete source mapping differs from upstream oracle output")
    inputs = json.loads((directory / "input.json").read_bytes())
    for group in ("source", "synthetic"):
        if len(inputs[f"{group}_queries"]) != len(expected[f"{group}_answers"]):
            raise ValueError("Missing registry oracle answers")
    count = sum(len(inputs[f"{group}_queries"]) for group in ("source", "synthetic"))
    print(f"Verified {count} registry oracle queries and {len(items)} complete mappings")


if __name__ == "__main__":
    main()
