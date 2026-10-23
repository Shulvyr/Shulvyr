"""Verify that invalid static registry contracts fail compilation."""

import argparse
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEADER = 'const registry = @import("registry");\nconst Row = registry.Row;\n'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="Pinned Zig executable")
    args = parser.parse_args()
    cases = [
        ("valid", '.{.{ .key = "test:a", .network_id = -7 }}', ".{0}", None),
        ("missing_index", '.{.{ .key = "test:a", .network_id = 7 }}', ".{}", "complete bounded network index"),
        ("duplicate_key", '.{.{ .key = "test:a", .network_id = 7 }, .{ .key = "test:a", .network_id = 8 }}', ".{0, 1}", "keys must be unique and sorted"),
        ("duplicate_network_id", '.{.{ .key = "test:a", .network_id = 7 }, .{ .key = "test:b", .network_id = 7 }}', ".{0, 1}", "network IDs must be unique and sorted"),
        ("duplicate_index", '.{.{ .key = "test:a", .network_id = 7 }, .{ .key = "test:b", .network_id = 8 }}', ".{0, 0}", "missing or duplicate mappings"),
        ("index_out_of_range", '.{.{ .key = "test:a", .network_id = 7 }}', ".{1}", "missing or duplicate mappings"),
        ("network_out_of_range", '.{.{ .key = "test:a", .network_id = 32768 }}', ".{0}", "network ID out of range"),
        ("invalid_key", '.{.{ .key = "stone", .network_id = 7 }}', ".{0}", "Invalid registry resource key"),
    ]
    with tempfile.TemporaryDirectory(prefix="shulvyr-registry-compile-") as temporary:
        directory = Path(temporary)
        for name, rows, order, expected in cases:
            source = directory / f"{name}.zig"
            source.write_text(
                HEADER + "comptime {\n"
                + f"    const rows: []const Row = &{rows};\n"
                + f"    const order: []const u32 = &{order};\n"
                + "    _ = registry.Registry(.item, i16, rows, order);\n}\n",
                encoding="ascii",
            )
            result = subprocess.run(
                [args.zig, "test", "--test-no-exec", "-fno-emit-bin", "--dep", "registry",
                 f"-Mroot={source}", f"-Mregistry={ROOT / 'src/registry/Registry.zig'}"],
                capture_output=True, text=True, timeout=60,
            )
            if expected is None:
                if result.returncode != 0:
                    raise RuntimeError(f"Valid registry failed compilation:\n{result.stderr}")
            elif result.returncode == 0 or expected not in result.stderr:
                raise RuntimeError(f"Unexpected compile result for {name}:\n{result.stderr}")
    print(f"Verified {len(cases)} registry compile contracts")


if __name__ == "__main__":
    main()
