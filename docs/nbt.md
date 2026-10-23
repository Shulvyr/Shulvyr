# NBT codec

`shulvyr.nbt` reads and writes one complete named root in big-endian,
little-endian or network little-endian format. It supports tags 1 through 11.
Network integers and collection lengths use signed ZigZag VarInts. Network
string lengths use unsigned VarInts. Shorts, floats and doubles retain fixed
little-endian encoding in network format.

The reference is the package set in
[PocketMine-MP 6a7cc02](https://github.com/pmmp/PocketMine-MP/blob/6a7cc02e9dff59b69241aa0bcffdb9903ce86beb/composer.lock):

| Oracle | Pinned source |
| --- | --- |
| NBT 1.2.0 | [51b8d6a](https://github.com/pmmp/NBT/tree/51b8d6a97065fb93e0b4f660b65164b6e1ed2fff) |
| BinaryUtils 0.2.7 | [14c044a](https://github.com/pmmp/BinaryUtils/tree/14c044afa33cb581b4a6d1ea04a87e0bc99e824b) |
| BedrockProtocol 58.0.1 | [8eb5a39](https://github.com/pmmp/BedrockProtocol/blob/8eb5a390a8d913ee54b97ac71f42899ecbb5c419/src/serializer/NetworkNbtSerializer.php) |

These LGPL-3.0 libraries are development-only oracles. Their source and runtime
are not included in the Zig package. The fixture generator calls their public
serializers with synthetic data. The checked-in wire bytes are not produced by
the Zig codec.

The package lock in [Axolotl-PM a550eea](https://github.com/axolotl-pm/PocketMine-MP/blob/a550eea48212504f95b824eb3a1d67fc3b7f1861/composer.lock)
uses the same NBT and BinaryUtils revisions. Its
[network serializer](https://github.com/axolotl-pm/BedrockProtocol/blob/7ff605d5b071d46c694d2b71bc8af4514156dbc2/src/serializer/NetworkNbtSerializer.php)
is identical to the pinned PMMP serializer. The tag set also agrees with
[Altay NBT 1.3.0](https://github.com/altayofficial/NBT/blob/2b1399b905db2937478435d596417c47e4120437/src/NBT.php)
and [Endstone's NBT types](https://github.com/EndstoneMC/endstone/blob/bb0475b64744106b328238b3f51d77576ddc6569/include/endstone/nbt/type.h).
[Dragonfly's level.dat adapter](https://github.com/df-mc/dragonfly/blob/1793369709ceed934675d69e86ff6c828e4216c8/server/world/mcdb/leveldat/level_dat.go)
keeps its file header separate from the little-endian NBT payload. These source
checks inform the scope here. They are not additional runtime conformance tests.

## Ownership and representation

`decode(allocator, input, format, limits)` validates the entire input and counts
required storage before allocating. The resulting `Document` owns a node slice
and an integer-array backing slice. Call `deinit` exactly once. Names, strings and
byte arrays borrow the input, which must remain immutable and alive until then.
Allocation failures free any storage already acquired.

Nodes are in depth-first order, starting at root index zero. Compound and list
values contain `Children` with a first index and count. Follow `next_sibling`
exactly that many times. List elements have empty names. A child's descendants
appear before its next sibling. Empty collections have no first index.

`encodedSize(nodes, format, limits)` validates the whole tree and returns its
encoded size. `encode(output, nodes, format, limits)` writes into caller-owned
storage and returns the written slice. It performs no allocations. Nodes must
form a single tree in depth-first order. Cycles, repeated references, unreachable
nodes, inconsistent child counts and mixed list types are rejected. Output must
not overlap nodes or their referenced slices. Errors leave the output intact.
Keep the tree and all referenced storage immutable during both operations.

## Bounds and format policy

`Limits` caps input/output bytes, depth, node count, each collection's length,
each string's byte length, decoded allocation size and traversal work. Decoded
allocation size is exactly the requested node and integer storage, excluding
allocator bookkeeping. The same storage budget is checked when encoding.
Root depth is one, including a scalar root. The hard depth ceiling is 64.

A work unit is charged per node, per name/string/byte-array byte and per
integer-array element. Each decode or encode uses two bounded tree traversals.
Encoding also makes a linear pass over validated nodes to check slice overlap.
Fixed-width number operations, tag checks and sibling checks add constant work
per visited node or element. This bounds synchronous work, without a wall-clock
deadline or decompression. Callers must choose limits for their own boundary.

- Strings and names are raw bytes, capped at 32767 bytes to match the pinned
  serializers. No UTF-8 or Java modified UTF-8 conversion is performed.
- Float and double bits are preserved, including signed zero and NaN payloads.
- Integer arrays expose signed `i32` values in all formats, preserving each
  32-bit word. The pinned PHP oracle returns unsigned integers for fixed-width
  arrays and signed integers for network arrays. The wire bytes agree in both
  cases. Consumers porting a PMMP operation must preserve its interpretation of
  those words when comparing semantic results.
- Empty lists preserve their declared element type. Nonempty `TAG_End` lists,
  negative collection lengths and noncanonical network VarInts are rejected.
- Compound order and duplicate names are preserved. Map lookup and duplicate
  resolution belong to the consuming schema. This differs from PMMP's map model.
- Trailing data, unknown tag IDs and `TAG_LongArray` are rejected.
- Compression, anonymous/headless roots, concatenated roots, world-file headers,
  storage schemas and full Java-format interoperability are outside this API.

## Fixtures

The nine fixtures cover all supported tags, scalar roots and nested lists in
each format. They include integer extremes, raw strings, typed empty lists and
nested compounds. Tests assert decoded values and byte-for-byte encoding, with
cross-format checks against the independent oracle bytes. Separate malformed
cases exercise truncation, budgets, tree validation and allocation failure.

The manifest stores the oracle revisions, SHA-256 of the generator containing
the synthetic input definition, and each output's size and SHA-256. Verify it:

```sh
python tools/check_nbt_fixtures.py
```

To regenerate, use Git and 64-bit PHP 8.4 or newer. Start with clean checkouts at
the exact revisions above. No Composer install or dependency scripts are needed.
For example, with those checkouts under the ignored `work/nbt-reference` folder:

```sh
php tools/generate_nbt_fixtures.php work/nbt-reference/NBT work/nbt-reference/BinaryUtils work/nbt-reference/BedrockProtocol
python tools/check_nbt_fixtures.py
zig build test --summary all
```

The generator refuses other revisions or dirty checkouts. Regeneration requires
reviewing the manifest and byte changes. These fixtures establish the declared
codec behavior, not compatibility with a complete Bedrock client or world file.
