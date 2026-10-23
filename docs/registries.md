# Registry identities and generation

`catalog.Items` and `catalog.Biomes` are immutable identity tables. They expose
2,076 item type names and 89 biome names from the recorded BedrockData snapshot.
These are dictionary entries, not implemented gameplay features.

## Identity contract

- `Id` is a snapshot-local internal index. Never transmit or persist its backing
  integer. Adding or removing a key can change these indices.
- `NetworkId` wraps the source dictionary's numeric value. Item values retain
  their signed i16 representation. Biome values use a u32 container. These types
  do not define a packet or world-file encoding.
- `ResourceKey` borrows an explicit namespaced string such as `minecraft:stone`.
  Persist the key when referring to an item type or biome. A future block-state
  identity also needs its typed properties and schema version.

Internal and network ID types differ across domains and snapshots, including
when their integer widths match. Converting an integer into an internal ID does
not validate it. `get` rejects an out-of-range ID. `resolve` requires a valid,
case-sensitive key and an explicit namespace. `fromNetwork` returns null for an
unmapped number. Unknown values never become air or a default biome.

Keys accept ASCII lowercase letters, digits, `_`, `-` and `.` on each side of
one colon. Paths additionally accept `/`. Both parts must be nonempty and the
total length is at most 256 bytes. Parsing allocates nothing and retains the
caller's bytes. Keys returned from these static catalogs live for the process
lifetime. Lookups allocate nothing and binary-search the key or network index.

## Data provenance

The inputs in [data/bedrock](../data/bedrock/manifest.json) are exact upstream
blobs from [Axolotl-PM BedrockData master](https://github.com/axolotl-pm/BedrockData/tree/488f81d2ab95841337fb9331efe9d6b74ceddb07),
resolved from its default branch before this subsystem was implemented. The
manifest records the revision, byte lengths, SHA-256 hashes and CC0-1.0 license.
The upstream [license text](../data/bedrock/LICENSE) is preserved.

The source labels this snapshot `1.26.40.30`, protocol 2168. The separately
referenced [BedrockProtocol HEAD](https://github.com/axolotl-pm/BedrockProtocol/blob/59e48666b9ca82bdc8c60c518438e2fc3f5e1b60/src/ProtocolInfo.php)
labels its protocol 2193. They are separate references. These tables establish
neither a matching protocol adapter nor tested client compatibility.

Only name-to-number identities are generated here. Item component flags,
versions and base64 component NBT remain in the untouched source JSON for a
later item-definition adapter. The generator checks their schema and base64
encoding but does not interpret NBT or expose item components at runtime.
Biome source paths gain the explicit `minecraft:` namespace. Item metadata
variants, migrations and custom registrations need separate contracts before
they can use these identities.

## Reproduce and verify

The pinned Zig compiler is sufficient. Generation needs no network or upstream
runtime. Ordinary builds use the checked-in output directly.

```sh
zig build generate-registries
zig build check-tools --summary all
zig build check-fixtures --summary all
zig fmt --check build.zig build.zig.zon src data/bedrock/root.zig
zig build test --summary all
```

The generator verifies every input hash before parsing. It rejects duplicate
JSON keys, duplicate numeric IDs, unknown item fields or versions, malformed
resource keys, out-of-range integers and missing required mappings. File and
entry limits bound development-time input processing. It sorts keys and builds
a complete numeric lookup index. Output includes the source revision and
generator hash. Reordering JSON objects leaves the generated tables identical.

The local schema is independent of the data supplier. A replacement source can
provide the same six input files with a pinned HTTPS Git origin, branch, revision,
CC0-1.0 license and exact byte hashes. Changing suppliers does not change the
registry APIs. This does not extract fresh data from a game client. That import
tooling remains to be implemented. Preserve the recorded origin of existing
snapshots and review new data before replacing them.

The Zig compiler independently validates sorted unique keys, numeric ranges
and a complete permutation of network mappings. Compile-contract tests check
these failures using the pinned compiler. Runtime tests cover fixed dictionary
vectors, invalid IDs, domain separation and both lookup directions for every
entry. Zig tool tests compare every generated row against its source mapping.

## Lookup oracle

[Fixture inputs](../src/registry/fixtures/input.json) include synthetic signed
i16 boundaries, zero, missing values and selected source-dictionary queries.
The development generator calls `ItemTypeDictionary.fromStringId` and
`fromIntId` from the recorded Axolotl-PM BedrockProtocol default-branch revision.
It uses the recorded NBT revision only to construct an empty `CacheableNbt`
placeholder. Lookup methods do not inspect item components.

There are 39 query answers. The generator also resolves every source key and
its inverse through the upstream dictionary, then hashes all 2,076 mappings as
ASCII lines of `key`, tab, signed decimal ID and newline, sorted by key. Zig
tests compare that complete mapping hash and every query answer. Missing PHP
lookups raise `InvalidArgumentException`. Fixtures normalize that outcome to
`found: false`, which Zig exposes as null. Malformed keys and duplicate source
definitions remain deliberate validation boundaries in Shulvyr's generator.

The fixture manifest records input and expected-output hashes, source revisions,
the data snapshot hash and the generator hash. PHP sources and runtime remain
development-only. Expected answers and the mapping hash come from upstream
public methods, not from the Zig implementation.

The generator lives in [Shulvyr/reference-tools](https://github.com/Shulvyr/reference-tools).
Its regeneration workflow uses clean checkouts at the manifest revisions and
64-bit PHP 8.4 or newer in a disposable server checkout:

```sh
zig build check-fixtures --summary all
zig build test --summary all
```

When updating data, select a source and resolve its latest default branch, review schema
and version changes, replace the exact input blobs and update their manifest.
Regenerate, inspect the diff and run the checks before selecting the new
snapshot for any protocol or persistence adapter.

## Block-state schema

`BlockState.decode` requires one complete NBT root. `decodePrefix` returns the
first root's exact byte length. They extract a namespaced `name`, a `states`
compound and an optional i32 `version`, defaulting to zero. `PMMPDataVersion`
metadata is ignored for identity, following the reference. Other root fields
are rejected. This is an identity parser, not a saved-world importer or writer.

Properties retain distinct byte, int and raw-string values. They are sorted by
name. `eql` compares name and typed properties without comparing version.
`encodeProperties` returns the reference dictionary key: little-endian compound
NBT with sorted properties, or empty bytes for no properties. Encoding rejects
output that aliases the state or its borrowed data and preserves output on
failure. It does not serialize a full saved block state.

The returned state borrows names and string values from input. Temporary NBT
node allocations are released before returning. Keep input immutable and alive
while a state or its property views are used. A state owns no heap allocations.

The scalar schema covers every entry in the recorded canonical palette. Its
explicit guards are 32 properties, 128 bytes per property name and 256 bytes
per string value. Defaults also cap each NBT root at 4 KiB, depth 8, 128 nodes,
16 KiB of decoded storage and 16,384 work units per codec traversal. Callers can
lower the property count and configure codec limits. Duplicate root fields or
properties are rejected. Other property tag types are unsupported. These
guards are stricter than the reference's general-purpose NBT map container.

The canonical palette is another exact CC0 input in the data manifest.
Tests decode all 22,091 entries and compare a SHA-256 digest produced by the
upstream [BlockStateData](https://github.com/axolotl-pm/PocketMine-MP/blob/a550eea48212504f95b824eb3a1d67fc3b7f1861/src/data/bedrock/block/BlockStateData.php)
and [BlockStateDictionaryEntry](https://github.com/axolotl-pm/PocketMine-MP/blob/a550eea48212504f95b824eb3a1d67fc3b7f1861/src/network/mcpe/convert/BlockStateDictionaryEntry.php)
methods. Each digest
record contains u32 little-endian name length, name bytes, u32 little-endian
property-key length and property-key bytes, in palette order. Version is checked
separately. Fourteen synthetic schema cases and ten equality pairs cover missing
versions, metadata, property order, signed boundaries and invalid roots.

```sh
zig build check-fixtures --summary all
zig build test --summary all
```

Use clean checkouts at the fixture manifest revisions and 64-bit PHP 8.4 or
newer. The manifest hashes synthetic input, wire fixtures, expected results,
the canonical palette and the generator. The source classes remain development
oracles. Their LGPL-3.0-or-later headers are retained in the upstream checkouts.
The Zig package contains the CC0 data and generated fixture outputs.

## Runtime block palette

`BlockPalette.init` loads a sequence of network NBT roots and a parallel i32
metadata array. It validates two bounded passes, then owns three exact-sized
allocations: entries, a sorted index and canonical property-key bytes. Names and
original root bytes borrow the immutable input until `deinit`. Metadata is
copied. Do not copy a live owning palette or retain views after its destruction.

`NetworkId` is the root's position in the input sequence. `Id` is a separate
sorted internal index with an owner-lifetime ID. Choose a nonzero owner and do
not reuse it while stale IDs can exist. Access rejects foreign owners and
out-of-range indices. Network IDs require the correct palette context and are
not persistent identities. `source_sha256` hashes the original NBT input. The
data manifest separately records its metadata input and protocol provenance.

`find` matches name and canonical typed properties without comparing version.
It returns null for an unknown state. `findByMetadata` preserves the reference
rules: when a name has one unique metadata value, return its last input entry
for any supplied metadata. With multiple metadata values, return the last entry
matching the supplied value, or null. Metadata is not masked to four bits. The
recorded source uses values from 0 through 509.

Defaults cap a whole palette at 8 MiB, 65,536 roots, 32 MiB of requested live
heap storage and 67,108,864 build-work units. The memory bound includes retained
arrays and temporary NBT allocations, excluding allocator bookkeeping and stack
buffers. Root parsing keeps the `BlockState` defaults and reduces its available
allocation/work budget when necessary. Missing or extra metadata, duplicate
name/property identities and malformed roots are rejected with cleanup.

Work is charged for each root, input byte and property-key byte in each pass,
each compared byte and length comparison during sorting, and each input byte
hashed for source identity. A fallible heapsort propagates exhaustion. This
ledger bounds data-dependent work, without measuring CPU cycles or a wall-clock
deadline. Both lookup methods take a per-call comparison-work budget and
allocate no heap storage. They use bounded stack buffers for canonical keys.
State lookup additionally charges its name and property-key byte lengths.

The dictionary oracle uses public `BlockStateDictionaryEntry` and
`BlockStateDictionary` constructors. Tests verify state lookups for all 22,091
entries, both ID directions, every network-ID/metadata pair and 8,862 metadata
queries across all 1,477 names. Hashes are generated by upstream methods.
The first digest records u32 little-endian network ID followed by i32
little-endian metadata in input order. The second records nullable lookup IDs
as u32 little-endian values, using `0xffffffff` for null, with names sorted and
metadata queries ordered as in the fixture input.
Synthetic cases cover duplicate metadata, last-entry selection and the
single-metadata shortcut with multiple states. Additional tests cover lifetime
validation, every truncated synthetic stream, all allocation failures, sort-work
exhaustion and peak requested memory at its exact limit.

## Reference boundaries

[Axolotl-PM ItemTypeIds](https://github.com/axolotl-pm/PocketMine-MP/blob/a550eea48212504f95b824eb3a1d67fc3b7f1861/src/item/ItemTypeIds.php)
distinguishes internal item IDs from legacy or saved IDs.
[Its network dictionary](https://github.com/axolotl-pm/BedrockProtocol/blob/59e48666b9ca82bdc8c60c518438e2fc3f5e1b60/src/serializer/ItemTypeDictionary.php)
maps names and numbers separately.
[Altay's data helper](https://github.com/altayofficial/Altay/blob/d3965b7c4ca779657916780f47e5a7647fb53646/src/network/mcpe/convert/ItemTypeDictionaryFromDataHelper.php)
also separates palette identities from component NBT.
[Endstone's registry](https://github.com/EndstoneMC/endstone/blob/bb0475b64744106b328238b3f51d77576ddc6569/include/endstone/registry.h)
uses identifiers scoped to an object type.
[Dragonfly's item registry](https://github.com/df-mc/dragonfly/blob/1793369709ceed934675d69e86ff6c828e4216c8/server/world/item.go)
rejects duplicate implementations and missing runtime mappings, while its
[block registry](https://github.com/df-mc/dragonfly/blob/1793369709ceed934675d69e86ff6c828e4216c8/server/world/block_registry.go)
has an explicit finalize boundary.
[Dragonfly's block-state representation](https://github.com/df-mc/dragonfly/blob/1793369709ceed934675d69e86ff6c828e4216c8/server/world/block_state.go)
also separates the name, properties and version.
These source comparisons inform the identity contract. Their runtimes are not
part of this package or its current registry tests.
