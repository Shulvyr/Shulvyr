# NBT codec

`shulvyr.nbt` reads and writes one complete named root in big-endian,
little-endian or network little-endian format. It supports tags 1 through 11.
Network integers and collection lengths use signed ZigZag VarInts. Network
string lengths use unsigned VarInts. Shorts, floats and doubles retain fixed
little-endian encoding in network format.

Use [Axolotl-PM's default branch](https://github.com/axolotl-pm/PocketMine-MP/tree/stable)
as the maintained PocketMine behavior reference. Refresh NBT oracle sources from
their default branches and record the commits used to generate fixtures.

| Oracle | Default branch | Fixture revision |
| --- | --- | --- |
| [NBT](https://github.com/pmmp/NBT) | `stable` | [5429a21](https://github.com/pmmp/NBT/tree/5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3) |
| [BinaryUtils](https://github.com/pmmp/BinaryUtils) | `stable` | [14c044a](https://github.com/pmmp/BinaryUtils/tree/14c044afa33cb581b4a6d1ea04a87e0bc99e824b) |
| [Axolotl-PM BedrockProtocol](https://github.com/axolotl-pm/BedrockProtocol) | `master` | [59e4866](https://github.com/axolotl-pm/BedrockProtocol/tree/59e48666b9ca82bdc8c60c518438e2fc3f5e1b60) |

These LGPL-3.0 libraries are development-only oracles. Their source and runtime
are not included in the Zig package. The fixture generator calls their public
serializers with synthetic data. The checked-in wire bytes are not produced by
the Zig codec.

## Ownership and representation

`decode(allocator, input, format, limits)` validates the entire input and counts
required storage before allocating. The resulting `Document` owns a node slice
and an integer-array backing slice. Call `deinit` exactly once. Names, strings and
byte arrays borrow the input, which must remain immutable and alive until then.
Allocation failures free any storage already acquired.

`decodePrefix(allocator, input, format, limits)` validates and decodes only the
first named root. It returns a `Document` with the same ownership contract and
`bytes_read`, the exact number of input bytes belonging to that root. Advance
only after success and destroy the returned document exactly once. Remaining
bytes are not validated by that call. A sequence consumer must validate them and
bound total bytes, root count, cumulative work and retained storage separately.

For prefix decoding, byte and other limits apply to the first root. Input may
contain a larger tail. Exhausting the bounded reader while more input exists
returns `ByteLimit`. Truncated input within that bound returns `UnexpectedEnd`.
Structural validation and storage-budget checks still finish before allocation.
The strict `decode` entry point continues to reject trailing data before any
allocation.

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
- Strict decoding rejects trailing data. Unknown tag IDs and `TAG_LongArray`
  remain unsupported in both decoding entry points.
- Compression, anonymous/headless roots, whole-sequence allocation, world-file
  headers, storage schemas and full Java-format interoperability are outside
  this API.

## Fixtures

The twelve fixtures cover all supported tags, scalar roots, nested lists and
three-root sequences in each format. They include integer extremes, raw strings,
typed empty lists and nested compounds. Tests assert decoded values and byte-for-byte encoding, with
cross-format checks against the independent oracle bytes. Separate malformed
cases exercise truncation, budgets, tree validation and allocation failure.
Sequence fixtures come from the upstream `writeMultiple` API. Prefix tests
check their exact boundaries and re-encode each root against its independent
single-root bytes. A malformed suffix is rejected by the next prefix call.

The manifest stores each oracle's repository, default branch and exact revision,
SHA-256 of the generator containing the synthetic input definition, and each
output's size and SHA-256. Verify it:

```sh
zig build check-fixtures --summary all
```

To refresh, fetch each source's default branch and review changes to its
serializers and dependencies. Update the revisions in the generator and this
document, then regenerate fixtures and inspect their byte changes.

The optional generator is maintained in
[Shulvyr/reference-tools](https://github.com/Shulvyr/reference-tools).
Its regeneration workflow needs Git and 64-bit PHP 8.4 or newer with clean
checkouts at the exact revisions above. No Composer installation is needed.
Normal verification uses the local corpus and frozen producer metadata:

```sh
zig build check-fixtures --summary all
zig build test --summary all
```

The generator refuses other revisions or dirty checkouts. Regeneration requires
reviewing the manifest and byte changes. These fixtures establish the declared
codec behavior, not compatibility with a complete Bedrock client or world file.
