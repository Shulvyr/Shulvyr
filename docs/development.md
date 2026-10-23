# Development

The foundation uses Zig 0.17.0 and the Zig standard library. There are no external
Zig packages or runtime libraries. The build rejects other compiler versions.

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test --summary all
zig build test -Doptimize=safe --summary all
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
- `foundation/Pool.zig` makes one allocation and keeps slots at stable addresses.
  Handles validate owner, slot and generation. The owner ID identifies a pool
  lifetime and must not be reused while stale handles can exist. Remove values
  and free their owned resources before destroying the pool. A borrowed pointer
  expires on removal. Exhausted generations retire slots.
- `foundation/Queue.zig` is a fixed-capacity FIFO for one execution context. A
  failed push retains ownership with the caller. It provides no synchronization.
- `math/coordinates.zig` uses floor division for signed block coordinates.
  Local coordinates are always 0 through 15. Joining coordinates rejects i32
  overflow.
- `simulation/TickClock.zig` accepts elapsed monotonic nanoseconds. Tick zero is
  due immediately. Catch-up is capped per poll and missed wall-clock deadlines
  are returned as metrics. Logical ticks and pending jobs are not skipped.
- `simulation/Scheduler.zig` orders timers by logical deadline and insertion
  sequence. Cancel and dispatch return ownership of their payloads. Ticket IDs
  are never reused. Work is bounded by the fixed capacity.
- `simulation/JobStamp.zig` compares world identity, generation and revision with
  the owner's current stamp. The owner must resolve a live world first. The
  producer remains responsible for payload lifetime.
- `simulation/Runtime.zig` owns its timers and command queue. The finite runner
  uses `std.Io.Clock.awake`, stops at the configured logical tick and drains its
  internal stop commands during cleanup.

Tests contain manually specified wire and coordinate vectors, malformed-input
cases, deterministic timer scenarios, generation exhaustion and allocation
failure injection. CLI integration tests run the actual executable and check
stdout, stderr and exit status.

## Next boundaries

NBT variants, UUID and broader math, registry generation, PMMP oracle fixtures,
transport, world state and storage remain separate implementation steps. A
protocol target and dependency choices still need their client and fixture
evidence before those subsystems are introduced.
