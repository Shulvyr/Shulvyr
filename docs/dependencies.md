# Dependencies and recovery

The default server, core tests and fixture checks use Zig and its standard
library. `build.zig.zon` has no external package dependencies. They read local
files and do not fetch or execute Axolotl-PM, PocketMine-MP or another server.

## Existing external inputs

| Boundary | Current input | Upstream availability needed | Recovery and remaining work |
| --- | --- | --- | --- |
| Registry and block data | Checked-in CC0 BedrockData snapshot with revision and file hashes | No, for building, testing or regenerating current tables | Retain the complete snapshot and license. The generator accepts another supplier with the same schema and pinned provenance. A first-party importer for future client data is still missing. |
| Behavior and wire fixtures | Checked-in synthetic results from pinned reference serializers | No, for ordinary tests and fixture checks | Keep the bytes, source revisions, generator source and hashes. Recreating those reference results requires the reference source and its runtime. Future fixtures can use another independent producer with their own provenance. |
| Optional PHP oracle regeneration | Public APIs from the revisions recorded in fixture manifests, mostly Axolotl-PM for recent subsystems | Yes, when obtaining a fresh reference checkout and its dependencies | Existing fixtures remain usable if upstream disappears. A complete self-contained archive of every oracle toolchain has not been prepared. Do not make regeneration a normal build requirement. |
| Optional native WebRTC probe | libdatachannel, mbedTLS and their pinned submodules | Yes, on a fresh source fetch | This backend is separate from the server. Its production gates include source recovery and replacement through the owned transport interfaces. See [native transport](native-transport.md). |
| Maintenance and CI | Python for compiler bootstrap, registry generation and native build tooling, plus C/C++ tools for the native probe | Installation and fresh downloads need their distribution sources | These tools still need migration or a documented exception. New first-party tools use Zig. The core build does not invoke them when Zig is already installed. |

Fixture metadata checks a particular producer because it describes particular
recorded bytes. A source URL in that metadata is provenance, not a network call.
Do not rewrite it to disguise where the data came from. A new producer needs a
separately identified corpus and independent expected results.

## Source authority

Selected PocketMine behavior can be checked against a maintained fork, while
Shulvyr owns the implementation and public contracts. For network behavior,
use the target client's protocol documentation and observed client evidence.
Compare other implementations where useful. Agreement with one server's
serializer alone does not establish protocol compatibility.

Current reference fixtures provide useful regression coverage, but many use a
single producer. Broader independent fixtures and real-client checks remain
necessary. A green fixture test is not evidence that a client can join.
