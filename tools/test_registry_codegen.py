"""Check registry schema rejection, completeness and reproducible generation."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import generate_registries as generator


class RegistryCodegenTest(unittest.TestCase):
    def item(self, value=7, **changes):
        return {"runtime_id": value, "component_based": False, "version": 2, **changes}

    def test_duplicate_json_keys_are_rejected_at_every_depth(self):
        for raw in (b'{"a": 1, "a": 2}', b'{"a": {"id": 1, "id": 1}}'):
            with self.assertRaisesRegex(ValueError, "Duplicate JSON key"):
                generator.read_json(raw)

    def test_duplicate_network_ids_are_rejected(self):
        for kind, rows in (
            ("item", {"a:b": self.item(), "a:c": self.item()}),
            ("biome", {"one": 7, "two": 7}),
        ):
            with self.assertRaisesRegex(ValueError, "Duplicate .* network ID"):
                generator.parse_rows(rows, kind)

    def test_missing_mapping_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Missing required registry mapping"):
            generator.verify_mapping([("minecraft:stone", 1)], ["minecraft:air"])

    def test_schema_changes_require_explicit_support(self):
        for entry in ({"runtime_id": 7}, self.item(extra=1), self.item(version=3)):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                generator.parse_rows({"a:b": entry}, "item")

    def test_integer_types_and_ranges(self):
        for value in (True, 1.0, "1", -32769, 32768):
            with self.subTest(value=value), self.assertRaises(ValueError):
                generator.parse_rows({"a:b": self.item(value)}, "item")
        for value in (True, -1, 2**31):
            with self.assertRaises(ValueError):
                generator.parse_rows({"a": value}, "biome")
        self.assertEqual([("a:b", -32768)], generator.parse_rows({"a:b": self.item(-32768)}, "item"))
        self.assertEqual([("a:b", 32767)], generator.parse_rows({"a:b": self.item(32767)}, "item"))

    def test_keys_and_component_payloads(self):
        for name in ("stone", "a:", "a:B", "a:b:c", "a:b\x00", "a:b" + "x" * 256):
            with self.assertRaises(ValueError):
                generator.parse_rows({name: self.item()}, "item")
        for changes in ({"component_based": 1}, {"component_nbt": False}, {"component_nbt": "!!!!"}, {"component_nbt": "Zh=="}):
            with self.assertRaises(ValueError):
                generator.parse_rows({"a:b": self.item(**changes)}, "item")
        generator.parse_rows({"a:b": self.item(component_nbt="Zg==")}, "item")
        with self.assertRaises(ValueError):
            generator.parse_rows({"minecraft:plains": 1}, "biome")

    def test_empty_and_oversized_inputs(self):
        with self.assertRaises(ValueError):
            generator.parse_rows({}, "item")
        with self.assertRaisesRegex(ValueError, "byte limit"):
            generator.read_json(b" " * (generator.MAX_FILE_BYTES + 1))
        with self.assertRaises(ValueError):
            generator.parse_rows({str(index): 0 for index in range(generator.MAX_ENTRIES + 1)}, "biome")

    def test_output_does_not_depend_on_json_object_order(self):
        manifest, files = generator.load_inputs(generator.ROOT)
        expected = generator.render(manifest, files, "synthetic-generator-hash")
        reordered = dict(files)
        for name in ("required_item_list.json", "biome_id_map.json"):
            data = json.loads(files[name])
            reordered[name] = json.dumps(dict(reversed(list(data.items())))).encode()
        self.assertEqual(expected, generator.render(manifest, reordered, "synthetic-generator-hash"))

    def test_generated_rows_match_every_source_mapping(self):
        manifest, files = generator.load_inputs(generator.ROOT)
        output = generator.render(manifest, files, "synthetic-generator-hash").decode()
        items = json.loads(files["required_item_list.json"])
        biomes = json.loads(files["biome_id_map.json"])
        self.assertEqual(len(items) + len(biomes), output.count(".{ .key ="))
        for name, row in items.items():
            self.assertIn(f'.{{ .key = "{name}", .network_id = {row["runtime_id"]} }},', output)
        for name, value in biomes.items():
            self.assertIn(f'.{{ .key = "minecraft:{name}", .network_id = {value} }},', output)

    def test_hash_mismatch_missing_file_and_path_escape_are_rejected(self):
        original_manifest, files = generator.load_inputs(generator.ROOT)
        with tempfile.TemporaryDirectory(prefix="shulvyr-registry-") as temporary:
            root = Path(temporary)
            directory = root / "data/bedrock"
            directory.mkdir(parents=True)
            for name, data in files.items():
                (directory / name).write_bytes(data)
            manifest = json.loads(json.dumps(original_manifest))
            path = directory / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            generator.load_inputs(root)
            (directory / "biome_id_map.json").write_bytes(b"{}")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                generator.load_inputs(root)
            (directory / "biome_id_map.json").write_bytes(files["biome_id_map.json"])
            del manifest["files"]["LICENSE"]
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing or unexpected"):
                generator.load_inputs(root)
            manifest["files"]["../../outside"] = {"bytes": 0, "sha256": hashlib.sha256(b"").hexdigest()}
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing or unexpected"):
                generator.load_inputs(root)


if __name__ == "__main__":
    unittest.main()
