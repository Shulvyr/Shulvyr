# Dependencies and recovery

The default server, core tests and fixture checks use Zig and its standard
library. `build.zig.zon` has no external package dependencies. They read local
files and do not fetch or execute Axolotl-PM, PocketMine-MP or another server.

## Existing external inputs

| Boundary | Current input | Upstream availability needed | Recovery and remaining work |
| --- | --- | --- | --- |
| Registry and block data | Checked-in CC0 BedrockData snapshot with revision and file hashes | No, for building, testing or regenerating current tables | Retain the complete snapshot and license. The generator accepts another supplier with the same schema and pinned provenance. A first-party importer for future client data is still missing. |
| Behavior and wire fixtures | Checked-in synthetic results from pinned reference serializers | No, for ordinary tests and fixture checks | Keep the bytes, source revisions and hashes. The local reference-tools snapshot records published producer source hashes. Recreating reference results requires their original runtime. |
| Optional oracle regeneration | Generators in Shulvyr/reference-tools calling APIs recorded in fixture manifests | Yes, when obtaining a fresh reference checkout and its dependencies | Existing fixtures remain usable without it. The server repository contains no PHP scripts. A complete self-contained archive of every upstream oracle toolchain is still missing. |
| Optional native WebRTC probe | libdatachannel, mbedTLS and pinned submodules, built by the separate reference-tools harness | Yes, on a fresh source fetch | C/C++ and Python requirements stay outside core CI. A separate workflow retains source-hash checks and the existing interoperability tests. See [native transport](native-transport.md). |
| Registry maintenance | Zig generator, parser tests and compiler contracts | No | The pinned compiler and local CC0 inputs are sufficient. No Python scripts are shipped in this repository. |
| Compiler installation | Official Zig archive, pinned size and SHA-256 | Yes, for a fresh download | CI uses runner PowerShell and archive tools before Zig is available. With the compiler installed, build, tests and maintenance commands use Zig. |

Fixture metadata checks a particular producer because it describes particular
recorded bytes. A source URL in that metadata is provenance, not a network call.
Do not rewrite it to disguise where the data came from. A new producer needs a
separately identified corpus and independent expected results.

The [source pin](../data/reference-tools/source.json) freezes the first-party
[reference-tools repository](https://github.com/Shulvyr/reference-tools) and its
source-manifest digest. Normal checks match producer records against that local
snapshot. `zig build check-reference-tools -- --root PATH` additionally hashes
actual files in an explicitly supplied checkout, without executing them.

## Source authority

Selected PocketMine behavior can be checked against a maintained fork, while
Shulvyr owns the implementation and public contracts. For network behavior,
use the target client's protocol documentation and observed client evidence.
Compare other implementations where useful. Agreement with one server's
serializer alone does not establish protocol compatibility.

Current reference fixtures provide useful regression coverage, but many use a
single producer. Broader independent fixtures and real-client checks remain
necessary. A green fixture test is not evidence that a client can join.
