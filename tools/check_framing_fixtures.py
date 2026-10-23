"""Verify framing fixtures produced by the public Axolotl serializers."""

import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/transport/fixtures"
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest["schema"] != 1 or set(manifest["files"]) != {"framing.json"}:
        raise ValueError("Unsupported framing fixture manifest")
    oracle = manifest["oracle"]
    if (oracle["repository"] != "https://github.com/axolotl-pm/nethernet" or
            oracle["branch"] != "master" or oracle["license"] != "LGPL-3.0-or-later" or
            not re.fullmatch(r"[0-9a-f]{40}", oracle["revision"])):
        raise ValueError("Unexpected framing oracle source")
    generator = root / "tools/generate_framing_fixtures.php"
    if hashlib.sha256(generator.read_bytes()).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Framing generator changed without regenerating fixtures")
    data = (directory / "framing.json").read_bytes()
    entry = manifest["files"]["framing.json"]
    if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError("Framing fixture bytes differ from manifest")
    fixtures = json.loads(data)
    if fixtures["oracle"] != oracle or manifest["cases"] != {"send": 10, "receive": 11, "boundaries": 5}:
        raise ValueError("Framing fixture source or case set drifted")
    for group, count in manifest["cases"].items():
        if len(fixtures[group]) != count:
            raise ValueError("Framing case count mismatch")
    for case in fixtures["send"]:
        if case.get("error"):
            continue
        frames = [bytes.fromhex(value) for value in case["frames_hex"]]
        if any(not frame or len(frame) > case["capacity"] + 1 or
               frame[0] != len(frames) - index - 1 for index, frame in enumerate(frames)):
            raise ValueError("Invalid source framing countdown")
        if b"".join(frame[1:] for frame in frames) != bytes.fromhex(case["payload_hex"]):
            raise ValueError("Framing source bytes do not reconstruct the input")
    for case in fixtures["receive"]:
        if len(case["frames_hex"]) != len(case["results"]):
            raise ValueError("Missing receiver oracle result")
        if any(set(result) not in ({"pending"}, {"error"}, {"payload_hex"}) for result in case["results"]):
            raise ValueError("Invalid receiver result schema")
    print("Verified 10 sender cases, 11 receive sequences and 5 SCTP boundary cases")


if __name__ == "__main__":
    main()
