# Development

The foundation uses Zig 0.17.0 and the Zig standard library. There are no external
Zig packages or runtime libraries. The build rejects other compiler versions.

Behavior ports use [Axolotl-PM's default branch](https://github.com/axolotl-pm/PocketMine-MP/tree/stable)
as the maintained PocketMine baseline. Resolve the latest branch heads before
porting each subsystem and record the tested revisions with its fixtures.
Compare [Altay](https://github.com/altayofficial/Altay),
[Endstone](https://github.com/EndstoneMC/endstone),
[Dragonfly](https://github.com/df-mc/dragonfly) and relevant projects from the
[Bedrock Wiki catalog](https://wiki.bedrock.dev/servers/server-software#active-software)
when designing each subsystem. Preserve the selected behavior in differential
tests and record intentional deviations beside that subsystem's contract.

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test --summary all
zig build test -Doptimize=safe --summary all
python tools/check_nbt_fixtures.py
python tools/check_math_fixtures.py
python tools/generate_registries.py --check
python tools/check_registry_fixtures.py
python tools/test_registry_codegen.py
python tools/test_registry_compile.py
```

CI runs these checks on x86_64 Linux and Windows. To compile for another target
without attempting to execute its binaries:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=safe
zig build test-compile -Dtarget=x86_64-linux-musl -Doptimize=safe
```

## Module contracts

- `foundation/binary.zig` borrows input and output buffers. Failed reads restore
  the cursor, failed writes preserve the destination. Variable integers are
  canonical unsigned LEB128 with optional signed ZigZag encoding. Text uses a
  u32 byte-length prefix, a caller-provided byte limit and UTF-8 validation.
  These primitives do not define a Bedrock protocol adapter.
- `foundation/nbt.zig` validates named NBT roots before allocation and provides
  bounded big-endian, little-endian and network codecs. Documents own node and
  integer storage while borrowing names, strings and byte arrays from input.
  See [NBT contracts and oracle fixtures](nbt.md) for limits and format policy.
- `foundation/Uuid.zig` owns 16 canonical bytes and parses/formats hexadecimal
  8-4-4-4-12 text without allocation. Parsing accepts both letter cases and
  preserves nil, max and reserved bit patterns. `v4` sets version/variant bits
  in caller-supplied random bytes, following [RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html).
  The Bedrock adapter reverses each eight-byte half, matching
  [Axolotl-PM CommonTypes](https://github.com/axolotl-pm/BedrockProtocol/blob/59e48666b9ca82bdc8c60c518438e2fc3f5e1b60/src/serializer/CommonTypes.php).
  Buffer failures preserve cursors and output. The type carries identity data,
  without authenticating that identity or imposing PHP UUID parsing rules.
- `foundation/Pool.zig` makes one allocation and keeps slots at stable addresses.
  Handles validate owner, slot and generation. The owner ID identifies a pool
  lifetime and must not be reused while stale handles can exist. Remove values
  and free their owned resources before destroying the pool. A borrowed pointer
  expires on removal. Exhausted generations retire slots.
- `foundation/Queue.zig` is a fixed-capacity FIFO for one execution context. A
  failed push retains ownership with the caller. It provides no synchronization.
- `foundation/Mailbox.zig` transfers messages between execution contexts with
  bounded queue capacity and explicit backpressure. `foundation/OwnedBytes.zig`
  copies bounded immutable snapshots. See [worker ownership](jobs.md) for moves,
  allocator lifetime, closure and shutdown ordering.
- `math/coordinates.zig` uses floor division for signed block coordinates.
  Local coordinates are always 0 through 15. Joining coordinates rejects i32
  overflow.
- `math/Vec3.zig`, `math/Aabb.zig` and `math/VoxelRay.zig` provide f64 geometry
  and bounded voxel queries. See [geometry contracts](geometry.md) for precision,
  face ties, boundary behavior, budgets and oracle fixtures.
- `registry/ResourceKey.zig` validates explicit borrowed namespaced keys.
  `registry/catalog.zig` provides immutable item and biome identity maps with
  separate internal and network ID types. See [registry generation](registries.md)
  for source hashes, schema limits and snapshot scope.
- `simulation/TickClock.zig` accepts elapsed monotonic nanoseconds. Tick zero is
  due immediately. Catch-up is capped per poll and missed wall-clock deadlines
  are returned as metrics. Logical ticks and pending jobs are not skipped.
- `simulation/Scheduler.zig` orders timers by logical deadline and insertion
  sequence. Cancel and dispatch return ownership of their payloads. Ticket IDs
  are never reused. Work is bounded by the fixed capacity.
- `simulation/JobStamp.zig` compares world identity, generation and revision with
  the owner's current stamp. The owner must resolve a live world first. The
  producer remains responsible for payload lifetime.
- `simulation/StampedBytes.zig` releases stale result snapshots or transfers a
  current result once after the world owner resolves its live stamp.
- `simulation/Runtime.zig` owns its timers and command queue. The finite runner
  uses `std.Io.Clock.awake`, stops at the configured logical tick and drains its
  internal stop commands during cleanup.

Tests contain manually specified wire and coordinate vectors, malformed-input
cases, deterministic timer scenarios, generation exhaustion and allocation
failure injection. CLI integration tests run the actual executable and check
stdout, stderr and exit status.

## Next boundaries

Block-state registries, broader PMMP behavior fixtures,
transport, world state and storage remain separate implementation steps. A
protocol target and dependency choices still need their client and fixture
evidence before those subsystems are introduced.
