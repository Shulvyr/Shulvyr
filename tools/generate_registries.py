"""Generate immutable identity tables from verified BedrockData inputs."""

import argparse
import base64
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INPUTS = {"required_item_list.json", "biome_id_map.json", "protocol_info.json", "LICENSE"}
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_ENTRIES = 65_536
KEY = re.compile(r"[a-z0-9_.-]+:[a-z0-9_./-]+", re.ASCII)


def object_unique(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(data: bytes):
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("Registry input exceeds byte limit")
    return json.loads(data, object_pairs_hook=object_unique)


def integer(value, lower: int, upper: int) -> int:
    if type(value) is not int or not lower <= value <= upper:
        raise ValueError("Registry integer is out of range")
    return value


def resource_key(value: str) -> str:
    if not isinstance(value, str) or len(value) > 256 or not KEY.fullmatch(value):
        raise ValueError("Invalid namespaced registry key")
    return value


def parse_rows(data: dict, kind: str) -> list[tuple[str, int]]:
    if not isinstance(data, dict) or not 0 < len(data) <= MAX_ENTRIES:
        raise ValueError("Registry requires a bounded nonempty object")
    rows = []
    network_ids = set()
    for name, entry in data.items():
        if kind == "item":
            name = resource_key(name)
            if not isinstance(entry, dict) or set(entry) not in (
                {"runtime_id", "component_based", "version"},
                {"runtime_id", "component_based", "version", "component_nbt"},
            ):
                raise ValueError("Unsupported item dictionary schema")
            network_id = integer(entry["runtime_id"], -32768, 32767)
            integer(entry["version"], 0, 2)
            if type(entry["component_based"]) is not bool:
                raise ValueError("Item component flag must be a boolean")
            if "component_nbt" in entry:
                payload = entry["component_nbt"]
                if not isinstance(payload, str) or len(payload) > 131_072:
                    raise ValueError("Item component payload exceeds limit")
                decoded = base64.b64decode(payload, validate=True)
                if base64.b64encode(decoded).decode("ascii") != payload:
                    raise ValueError("Item component payload must be canonical base64")
        elif kind == "biome":
            if not isinstance(name, str) or ":" in name:
                raise ValueError("Biome source keys must be unqualified paths")
            name = resource_key("minecraft:" + name)
            network_id = integer(entry, 0, 2**31 - 1)
        else:
            raise ValueError("Unknown registry domain")
        if network_id in network_ids:
            raise ValueError(f"Duplicate {kind} network ID: {network_id}")
        network_ids.add(network_id)
        rows.append((name, network_id))
    return sorted(rows)


def verify_mapping(rows: list[tuple[str, int]], required: list[str]) -> None:
    """Fail before generation when an implementation requests an absent mapping."""
    names = {name for name, _ in rows}
    for name in required:
        if resource_key(name) not in names:
            raise ValueError(f"Missing required registry mapping: {name}")


def load_inputs(root: Path) -> tuple[dict, dict]:
    directory = root / "data/bedrock"
    manifest = read_json((directory / "manifest.json").read_bytes())
    if set(manifest) != {"schema", "source", "files"} or manifest["schema"] != 1:
        raise ValueError("Unsupported registry manifest schema")
    source = manifest["source"]
    if source != {
        "repository": "https://github.com/axolotl-pm/BedrockData",
        "branch": "master",
        "revision": source.get("revision"),
        "license": "CC0-1.0",
    } or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
        raise ValueError("Registry source requires a pinned BedrockData revision")
    if set(manifest["files"]) != INPUTS:
        raise ValueError("Registry manifest has missing or unexpected files")
    files = {}
    for name in sorted(INPUTS):
        expected = manifest["files"][name]
        path = directory / name
        if path.stat().st_size > MAX_FILE_BYTES:
            raise ValueError(f"Registry input exceeds byte limit: {name}")
        data = path.read_bytes()
        if expected != {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}:
            raise ValueError(f"Registry input hash mismatch: {name}")
        files[name] = data
    return manifest, files


def render(manifest: dict, files: dict, generator_hash: str) -> bytes:
    items = parse_rows(read_json(files["required_item_list.json"]), "item")
    biomes = parse_rows(read_json(files["biome_id_map.json"]), "biome")
    verify_mapping(items, ["minecraft:air", "minecraft:stone"])
    verify_mapping(biomes, ["minecraft:ocean", "minecraft:plains"])
    version = read_json(files["protocol_info.json"])["version"]
    if set(version) != {"major", "minor", "patch", "revision", "beta", "protocol_version"}:
        raise ValueError("Unsupported source version schema")
    for name in ("major", "minor", "patch", "revision", "protocol_version"):
        integer(version[name], 0, 2**31 - 1)
    if type(version["beta"]) is not bool:
        raise ValueError("Source beta marker must be a boolean")
    source = manifest["source"]
    lines = [
        "// Generated by tools/generate_registries.py. Do not edit.",
        "// Source data: CC0-1.0, see data/bedrock/LICENSE.",
        'const Row = @import("Registry.zig").Row;',
        "",
        "pub const source = .{",
        f'    .repository = "{source["repository"]}",',
        f'    .branch = "{source["branch"]}",',
        f'    .revision = "{source["revision"]}",',
        f'    .generator_sha256 = "{generator_hash}",',
        f'    .protocol = @as(u32, {version["protocol_version"]}),',
        '    .version = "' + ".".join(str(version[x]) for x in ("major", "minor", "patch", "revision")) + '",',
        f'    .beta = {str(version["beta"]).lower()},',
        "};",
    ]
    for kind, rows in (("item", items), ("biome", biomes)):
        lines += ["", f"pub const {kind}s = [_]Row{{"]
        for key, network_id in rows:
            lines.append(f'    .{{ .key = "{key}", .network_id = {network_id} }},')
        lines += ["};", "", f"pub const {kind}_network_order = [_]u32{{"]
        for index in sorted(range(len(rows)), key=lambda index: rows[index][1]):
            lines.append(f"    {index},")
        lines.append("};")
    return ("\n".join(lines) + "\n").encode("ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated output differs")
    args = parser.parse_args()
    manifest, files = load_inputs(ROOT)
    generated = render(manifest, files, hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    destination = ROOT / "src/registry/generated.zig"
    if args.check:
        if destination.read_bytes() != generated:
            raise ValueError("Registry output is stale. Run python tools/generate_registries.py")
        print("Verified registry input hashes, schemas and generated output")
    else:
        destination.write_bytes(generated)
        print(f"Generated {destination.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
