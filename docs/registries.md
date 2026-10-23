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
Biome source paths gain the explicit `minecraft:` namespace. Block states,
item metadata variants, migrations and custom registrations need separate
contracts before they can use these identities.

## Reproduce and verify

Python 3.12 or newer is sufficient. Generation needs no network or upstream
runtime. Ordinary Zig builds use the checked-in output directly.

```sh
python tools/generate_registries.py
python tools/generate_registries.py --check
python tools/check_registry_fixtures.py
python tools/test_registry_codegen.py
python tools/test_registry_compile.py
zig fmt --check build.zig build.zig.zon src
zig build test --summary all
```

The generator verifies every input hash before parsing. It rejects duplicate
JSON keys, duplicate numeric IDs, unknown item fields or versions, malformed
resource keys, out-of-range integers and missing required mappings. File and
entry limits bound development-time input processing. It sorts keys and builds
a complete numeric lookup index. Output includes the source revision and
generator hash. Reordering JSON objects leaves the generated tables identical.

The Zig compiler independently validates sorted unique keys, numeric ranges
and a complete permutation of network mappings. Compile-contract tests check
these failures using the pinned compiler. Runtime tests cover fixed dictionary
vectors, invalid IDs, domain separation and both lookup directions for every
entry. Python tests compare every generated row against its source mapping.

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

To regenerate, use clean source checkouts at the manifest revisions and
64-bit PHP 8.4 or newer:

```sh
php tools/generate_registry_fixtures.php /path/to/NBT /path/to/BedrockProtocol
python tools/check_registry_fixtures.py
zig build test --summary all
```

When updating data, resolve the latest upstream default branch, review schema
and version changes, replace the exact input blobs and update their manifest.
Regenerate, inspect the diff and run the checks before selecting the new
snapshot for any protocol or persistence adapter.

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
These source comparisons inform the identity contract. Their runtimes are not
part of this package or its current registry tests.
