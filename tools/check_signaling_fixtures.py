"""Check independently generated signaling fixture provenance and integrity."""
import hashlib
import json
from pathlib import Path
import re


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    directory = root / "src/transport/fixtures"
    manifest = json.loads((directory / "signaling-manifest.json").read_bytes())
    oracle = manifest["oracle"]
    if (manifest["schema"] != 1 or manifest["cases"] != 30 or
            oracle != {"repository": "https://github.com/axolotl-pm/nethernet",
                       "branch": "master", "revision": "6ecacdaed3b0605a6a523235e5536f9c09ea56fd",
                       "license": "LGPL-3.0-or-later"}):
        raise ValueError("Unexpected signaling oracle or case set")
    generator = (root / "tools/generate_signaling_fixtures.php").read_bytes()
    if hashlib.sha256(generator).hexdigest() != manifest["generator_sha256"]:
        raise ValueError("Signaling generator changed without regenerating fixtures")
    raw = (directory / "signaling.json").read_bytes()
    if len(raw) != manifest["bytes"] or hashlib.sha256(raw).hexdigest() != manifest["sha256"]:
        raise ValueError("Signaling fixture bytes differ from manifest")
    fixtures = json.loads(raw)
    if fixtures["oracle"] != oracle or len(fixtures["cases"]) != 30:
        raise ValueError("Signaling source or case count drifted")
    names = set()
    for case in fixtures["cases"]:
        if case["name"] in names:
            raise ValueError("Duplicate signaling case")
        names.add(case["name"])
        wire = bytes.fromhex(case["wire_hex"])
        if case.get("error"):
            if set(case) != {"name", "wire_hex", "error"} or case["error"] is not True:
                raise ValueError("Invalid signaling rejection schema")
            continue
        if (case["kind"] not in {"CONNECTREQUEST", "CONNECTRESPONSE", "CANDIDATEADD", "CONNECTERROR"} or
                not re.fullmatch(r"0|[1-9][0-9]*", case["connection_id"]) or
                int(case["connection_id"]) > (1 << 64) - 1):
            raise ValueError("Invalid oracle signal identity")
        data = bytes.fromhex(case["data_hex"])
        encoded = bytes.fromhex(case["encoded_hex"])
        if encoded != case["kind"].encode() + b" " + case["connection_id"].encode() + b" " + data:
            raise ValueError("Oracle output schema is inconsistent")
        if wire.split(b" ", 2)[2] != data:
            raise ValueError("Oracle did not preserve opaque data")
    print("Verified 30 independent signaling oracle cases")


if __name__ == "__main__":
    main()
