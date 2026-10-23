"""Verify block-state schema fixtures and the upstream palette digest."""

import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/registry/fixtures/blocks"
    manifest = json.loads((directory / "manifest.json").read_bytes())
    if manifest["schema"] != 1:
        raise ValueError("Unsupported block fixture schema")
    oracles = {
        "NBT": ("https://github.com/pmmp/NBT", "stable"),
        "BinaryUtils": ("https://github.com/pmmp/BinaryUtils", "stable"),
        "BedrockProtocol": ("https://github.com/axolotl-pm/BedrockProtocol", "master"),
        "PocketMine-MP": ("https://github.com/axolotl-pm/PocketMine-MP", "stable"),
    }
    if set(manifest["oracles"]) != set(oracles):
        raise ValueError("Unexpected block-state oracles")
    for name, (repository, branch) in oracles.items():
        source = manifest["oracles"][name]
        if source["repository"] != repository or source["branch"] != branch or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
            raise ValueError("Block oracle requires its source revision")
    generator = root / "tools/generate_block_fixtures.php"
    if hashlib.sha256(generator.read_bytes()).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Block generator changed without regeneration")
    inputs = json.loads((directory / "input.json").read_bytes())
    if not 0 < len(inputs["cases"]) <= 64:
        raise ValueError("Block fixtures require bounded cases")
    expected_files = {"input.json", "expected.json"} | {f"case-{index}.network.nbt" for index in range(len(inputs["cases"]))}
    if set(manifest["files"]) != expected_files or {path.name for path in directory.iterdir()} != expected_files | {"manifest.json"}:
        raise ValueError("Block fixture files differ from manifest")
    for name, expected in manifest["files"].items():
        data = (directory / name).read_bytes()
        if expected != {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}:
            raise ValueError(f"Block fixture hash mismatch: {name}")
    data_manifest = json.loads((root / "data/bedrock/manifest.json").read_bytes())
    palette = (root / "data/bedrock/canonical_block_states.nbt").read_bytes()
    digest = hashlib.sha256(palette).hexdigest()
    if data_manifest["files"]["canonical_block_states.nbt"] != {"bytes": len(palette), "sha256": digest}:
        raise ValueError("Palette bytes differ from the data manifest")
    if manifest["data_source"] != data_manifest["source"] or digest != manifest["palette_sha256"]:
        raise ValueError("Block fixtures use a different palette snapshot")
    expected = json.loads((directory / "expected.json").read_bytes())
    if len(expected["cases"]) != len(inputs["cases"]) or len(expected["equalities"]) != len(inputs["equality_pairs"]):
        raise ValueError("Missing block oracle answers")
    for index, case in enumerate(expected["cases"]):
        if case["file"] != f"case-{index}.network.nbt":
            raise ValueError("Block case has an unexpected wire fixture")
    summary = expected["palette"]
    if not 0 < summary["names"] <= summary["roots"] <= 65536 or not re.fullmatch(r"[0-9a-f]{64}", summary["semantic_sha256"]):
        raise ValueError("Invalid full-palette oracle digest")
    print(f"Verified {len(inputs['cases'])} block schema cases and {summary['roots']} palette states")


if __name__ == "__main__":
    main()
