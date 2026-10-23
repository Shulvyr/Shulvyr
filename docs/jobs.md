# Worker message ownership

`Mailbox(T, capacity)` transfers values between execution contexts through a
bounded `std.Io.Queue`. It uses the pinned compiler's queue implementation rather
than introducing another synchronization algorithm. Each operation transfers at
most one message. Capacity must be 1 through 65,536 and elements must be nonempty.

Initialize a mailbox with `init` at its final address before sharing it. Its
inline slot storage, queue and address must remain alive until every producer
and consumer has stopped. Do not copy or reinitialize a live mailbox. There is
no heap allocation inside the mailbox itself.

## Transfer and backpressure

`send` takes a pointer to an optional caller-owned message. Success sets that
optional to null and transfers ownership. `QueueFull`, `Closed` and other errors
leave the message with the caller. Retry, cancel or free it explicitly.

`receive` returns one owned message or null when an open queue is empty. Both
operations use the standard queue's `min=0` mode. They do not wait for queue space
or incoming messages. The underlying queue still synchronizes its critical
sections. This is not a lock-free or wait-free contract.

`close` rejects future sends and allows existing messages to drain. After the
last queued message, receivers get `Closed`. Closing is idempotent and does not
free messages. The shutdown owner must stop producers and workers, join them,
then drain and destroy remaining payloads before releasing mailbox storage.
Never wait for a worker while its completion still requires that owner to drain
a full result queue. A worker must retain or release an unsent result when its
destination closes.

## Immutable snapshots and result validation

`OwnedBytes.copy` checks the caller's payload byte limit before allocating and
copies the input. It retains no input references. `bytes` exposes a read-only
view until `take` or `deinit`. `take` moves ownership and empties the source.
`deinit` releases the allocation and leaves a safely destructible empty value.
An empty snapshot needs no allocation.

The allocator must outlive the snapshot and support every execution context
that frees it. Do not copy a live owning value, mutate its storage, or retain a
borrowed view after ownership has moved. Zig does not enforce these move and
lifetime rules in the type system. Use `copy`, `take` and mailbox transfer rather
than constructing owning fields directly.

`StampedBytes(WorldHandle)` pairs a snapshot with `JobStamp`: world identity,
handle generation and revision. Only the world owner resolves the live world
and calls `takeIfCurrent`. A matching stamp transfers the payload once. A stale
stamp, cancellation or unload releases it and returns null. Supply null when
the job has been canceled or the world no longer exists. Repeated acceptance
returns null, including for zero-length messages.

This check does not resolve world handles, authenticate a worker, deduplicate
separately copied messages or define transaction ordering. Per-job tickets,
cooperative cancellation of running work, time limits, a worker pool and
subsystem commit rules remain later integration work. Queue capacity bounds
queued message count. Producers must choose a consistent per-payload limit and
account separately for input copies, in-flight work and unsent results.

## Evidence and scope

Tests cover FIFO wrap, queue saturation, closure/draining, retained sender
ownership, allocation failure, scratch-buffer reuse and one-time result
consumption. They transfer 64 snapshots through bidirectional queues with an
actual OS worker thread. A separate case closes a saturated result queue while
the worker owns an unsent snapshot and checks cleanup through the test
allocator. These are bounded lifecycle tests, not race detection or a soak run.

[Axolotl-PM AsyncTask](https://github.com/axolotl-pm/PocketMine-MP/blob/a550eea48212504f95b824eb3a1d67fc3b7f1861/src/scheduler/AsyncTask.php)
separates worker execution from completion on the main server thread. This
checkpoint retains that ownership boundary without implementing its PHP task
API. The finite foundation runner still creates no worker pool or world.
