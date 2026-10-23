# Transport framing and sessions

`framing` and `TransportSession` provide the owner-side boundary between copied
data-channel frames and application messages. They allocate no heap memory.
The native provider, signaling, authentication and Bedrock packet adapters have
separate responsibilities. The server runner does not open a network listener.
The bounded [signaling text codec](signaling.md) handles its own envelope and
resource limits before a future negotiation layer processes payload data.

## Wire behavior

The one-byte countdown follows
[Mojang's NetherNet guide](https://github.com/Mojang/bedrock-protocol-docs/blob/4fbe153e04e56645addc681259e398b94c60d14f/additional_docs/NetherNetOnboardingGuide.md#61-nethernet-data-framing).
Header zero finishes a message. Reliable fragments count down consecutively.
Unreliable messages require header zero and cannot be fragmented.

The selected behavior reference is the current Axolotl NetherNet default-branch
revision [6ecacda](https://github.com/axolotl-pm/nethernet/tree/6ecacdaed3b0605a6a523235e5536f9c09ea56fd/src/protocol/framing).
Sending supports 255 fragments and emits no frames for an empty application
message. Receiving rejects an empty frame or a header without a payload.
A broken countdown discards the incomplete message. The standalone receiver
can then accept a new message, matching the reference assembler.

The reference receiver also accepts a starting countdown of 255, representing
256 short fragments, subject to its byte budget. Sending still stops at 255
fragments. Both paths are covered by oracle cases. These are source behavior
checks, not a claim about what every Minecraft client accepts.

The [Dragonfly transport](https://github.com/df-mc/go-nethernet/blob/215e46422b5831d6ddc6146003617dc3f1ff7c26/conn.go)
agrees on the send count and serializes a whole reliable message to prevent
interleaving. [Endstone's framing code](https://github.com/EndstoneMC/nethernet-python/blob/339eb5a65582098af4152f27ed5c855ba205c65d/src/nethernet/transport/framing.py)
agrees on the nonempty send boundaries. Its empty-message and malformed-receive
behavior is more permissive. Shulvyr follows Axolotl for those cases.

## Bounds and ownership

`Limits.frame_bytes` includes the header and ranges from 2 through 262,144.
`Limits.message_bytes` is at most 66,846,465, the reference sender's byte ceiling.
Both limits are checked before copying. A receiver borrows caller-provided
storage sized for its message limit. Unreliable storage needs only the smaller
of that limit and the frame payload capacity. Channel storage must be disjoint.

`Sender` borrows immutable input until its final fragment is committed. `write`
prepares the current frame without advancing. `commit` advances after provider
admission succeeds. A full queue must leave the current fragment pending.
Do not interleave fragments from another reliable application message. A failure
after partial transmission requires closing the connection rather than starting
an unrelated message in the middle of its countdown.

The written output region cannot alias sender metadata or borrowed input. Incoming frames
cannot alias receiver/session metadata or either channel's storage. Local
aliasing errors preserve the live state. Receiving copies frame payload bytes
synchronously. Completed views borrow their channel's storage until its next
accept, reset or close. Copy a view before handing it to another execution
context or retaining it across those calls.

Assembly time is measured from the first fragment and is not refreshed by later
fragments. The default is ten seconds, a local resource policy rather than a
wire constant. Call `poll` when no input arrives so abandoned sequences expire.
Times are monotonic u64 nanoseconds supplied by the owner. Elapsed subtraction
avoids deadline-addition overflow. A backwards clock is an error.

## Session lifecycle

A session starts negotiating. It opens after both expected channels have valid
settings: ordered and reliable, or unordered with zero retransmissions and no
packet lifetime override. Labels are exact. Duplicate opens or invalid settings
close the session. The negotiation deadline is required at initialization.
Transport-open state does not establish an authenticated player or game login.
Before both channels open, `accept` returns `NotOpen`. The owner must retain
that event in bounded storage or close the peer rather than silently lose it.

Every callback event carries a scoped `Id` with owner, slot and generation.
The owner must never reuse a lifetime identity while stale events can exist.
These values are internal handles, separate from NetherNet's wire NetworkID.
An event with an old identity is rejected before changing a clock, buffer or
session state. A reconnect uses a new generation. Native callback contexts must
remain alive through provider callback quiescence, even after the session closes.

Malformed data for the current session closes both channels' logical state and
discards incomplete assemblies. The native adapter must then close its peer.
Closure is idempotent and records the first close reason. Caller storage remains
owned by the caller.
The core does not call a native library or free callback contexts.

## Callback ingress and teardown

`Inbox(capacity)` binds concurrent provider callbacks to one scoped session
identity and one owner. Initialize it at its final address before registering
callbacks. Keep the allocator and inbox alive through every callback and lease.
The allocator must support concurrent allocation and freeing across those
contexts. Providers must serialize callbacks within each channel.

`post` validates identity and frame length, then reserves count and byte credits
before allocation. Credits cover in-flight copies, queued frames and leases
held by the owner. A lease frees its snapshot before returning credits. Payload
accounting excludes allocator overhead, inline metadata and native buffers.
Neither queue admission nor stop waits for the owner to make space. Mutexes and
the allocator may still wait, so these operations have no hard time guarantee.

Saturation, malformed lengths and allocation failure stop further admission.
The first stop reason is stored outside the queue and survives a full queue or
a later native close. Stale identities reject before changing that reason.
`applyStop` propagates termination to the logical session on its owner.

`receive` transfers a copied frame lease. `Lease.accept` checks the current
session, applies sticky termination and invokes the bounded receiver. A frame
can be accepted only once. `NotOpen` retains it for retry after negotiation.
Complete application bytes borrow the session receiver, independent of the
frame lease's allocation. Release every lease, including on errors.

Stop does not destroy a native peer or establish a callback barrier. The owner
must stop admission, unregister/delete provider resources using their actual
barriers, and release all frame leases. `discard(limit)` releases a bounded
number of queued frames after stop. A closed, empty queue can still have
in-flight copies or live leases. Zero outstanding alone cannot prove that a
future native callback will not run. Deinitialize only after producers have
quiesced and all reservations, frames and leases have retired.

## Outbound admission and completion

`Outbox(capacity)` belongs to one session lifetime and one owner. It keeps
separate channel FIFOs so a blocked reliable message does not prevent an
unreliable send. Reliable messages never interleave their fragment sequences.
The shared slot limit includes queued messages, receipts awaiting drain and
completed results the consumer has not collected. Completion backpressure
therefore cannot silently lose a result.

`enqueueOwned` moves a snapshot only on success. Failure leaves it with the
caller. `enqueueCopy` checks framing, capacity and byte budgets before allocating.
The retained-payload byte counter covers full snapshots until their last frame
has been copied by the sink. Allocator rounding, inline queue storage and native
transport buffers need separate accounting.

`FrameSink` is a synchronous borrowed adapter bound to the same scoped session
identity. Stale provider identities reject before a callback can run. Accepted
frames must have been copied before return. Blocked sends accept nothing.
The adapter cannot reenter the outbox or keep a scratch-buffer pointer.

`pump` caps work steps and accepted wire bytes, including fragment headers.
One step may make at most three sink calls. Scratch preflight scans the fixed
queue capacity before those steps and rejects overlap with live payloads,
session buffers or metadata. A zero-step budget performs no sink calls.
The reported native byte limit is shared across both channels. All application
sends to the bound native channels must use the same owner and admission path.

Completion follows the
[Axolotl Session receipt rule](https://github.com/axolotl-pm/nethernet/blob/6ecacdaed3b0605a6a523235e5536f9c09ea56fd/src/session/Session.php):
a message becomes `drained` when the cumulative queued wire-byte watermark is
no larger than the queued byte total minus the provider's current buffered
amount. Receipts stay FIFO within each channel and may interleave across channels.
This is a local queue observation, not a peer-delivery acknowledgement. Empty
messages also wait for a provider observation. Counters refuse exhaustion
before ownership moves.

Provider errors close the logical session, release unresolved payloads and
publish `failed` completions with the number of frames already accepted.
`shutdown` publishes `cancelled` results and preserves an earlier close reason.
The owner must close the actual native peer after failure or cancellation,
especially after a partial reliable send. Drain completions before discarding
them if their outcomes matter. Call shutdown before deinit when work remains.

The native
[buffered-amount API](https://libdatachannel.org/pages/reference.html#rtcgetbufferedamount)
excludes transport-level buffering. These limits do not establish a bound on
all libdatachannel, SCTP or TLS memory. Native control traffic and production
provider resource limits remain part of the provider gate.

## Provider finalization worker

`Reaper(capacity)` has one owner and one management worker. Reserve a scoped
ticket before publishing a native connection that will need cleanup. Capacity
covers reservations, queued/running finalizers, uncollected completions and
retained contexts. One reservation per session prevents duplicate submission.
Exhausted ticket generations retire their slots.
The reaper's owner ID identifies its lifetime and must not be reused while old
tickets can exist, matching the underlying pool's ownership rule.
Credits end when ownership returns. Connection pools must account separately
for returned context memory and native provider allocations.

`submit` moves a provider task only on success. It validates the ticket and
session identity before transfer. The worker runs the provider finalizer,
which may wait for native callback barriers but must not access owner state,
reenter the reaper or depend on owner work. It must leave its context allocated.
The context's address and referenced buffers must remain valid until the owner
takes it back, including while a failed task waits for retry.
Only a successful finalizer may assert that all users of the context have
quiesced. The reaper cannot independently verify a provider's assertion.

Each submitted task produces one scalar completion. Retained reservation
credits guarantee room in the completion mailbox even if its owner stops
collecting. `collect` never waits for a job. It records the outcome without
releasing the context or its credit. The owner checks the returned session
before changing connection state.

`takeFinalized` returns a quiesced context once and releases its credit. Failed
contexts remain held, cannot be canceled or taken, and can be retried with their
original finalizer. Providers must preserve partial progress safely across
retries. A permanently failing or stuck finalizer retains its context and may
prevent shutdown. No deadline forcibly frees callback state or kills a thread.

`requestStop` refuses new reservations while allowing existing reservations
to submit cleanup. Only unused reservations can be canceled. Shutdown still
requires collecting results, retrying failures and taking quiesced contexts.
The job queue closes once every credit has returned. `join` refuses outstanding
work, so it cannot wait for a result the caller still needs to collect.
`tryJoin` supports owner polling. Deinitialize only after worker exit is joined.

## Owner connection controller

`Connection(send_capacity, receive_capacity, reaper_capacity)` owns one logical
session, inbox and outbox at a fixed address. It borrows receive storage, a
thread-safe allocator and a shared reaper. Initialization reserves cleanup
capacity before any provider is created. Attach a scoped `Provider` containing
the sink and finalizer before publishing native callbacks. Attachment transfers
ownership only on success. An unattached connection can cancel its reservation
without a native task. This controller does not allocate a connection registry
or implement a listener, signaling, authentication or a persistent server loop.

The owner validates channel opens and calls `beginTick` once per increasing
tick with monotonic nanoseconds, sender scratch and explicit work budgets.
Stale identities, ticks, clocks and aliased scratch reject before work. Existing
drain receipts are observed before processing native termination. These control
observations make at most six provider queries and `2 * send_capacity` scalar
completions in addition to the sender budget. They run even with zero send steps.
Provider calls must remain synchronous and must not wait for owner work.
During negotiation, `limitSendFrame` may lower each channel's sender frame
ceiling before application admission. It cannot raise a configured ceiling or
change an open connection's queued work. Providers use it for negotiated native
message limits before reporting channel opens.

Pull `nextEvent` only when the application can accept it. Events prioritize open,
send outcomes, logical close, cleanup failure and final retirement before input.
An open that has not been published is suppressed on close, along with its
corresponding close notification. Message payloads borrow receiver storage until
the next connection mutation. Each tick permits at most 64 complete messages
and the supplied receive frame/byte budgets. A frame that exceeds the remaining
byte budget retains its inbox lease and credits for a later tick. No complete
application message is pulled while draining or closing.

`disconnect` refuses new application sends and flushes already admitted work.
Its two-second grace period starts on the first owner update, and repeated
requests do not extend it. Final drain receipts precede the close event, including
at the deadline. A flush completes when both provider buffers and pending send
queues are empty. Normal remote closure during grace preserves the requested
disconnect reason. An explicit failed transport remains a failure. Expiry
reports `flush_expired`, cancels unresolved sends and starts native cleanup.
Local queue drain still does not establish remote delivery.

`forceClose` stops admission and logical state, releases any held frame and
submits the provider finalizer to the reserved reaper slot. Native callbacks
retain only inbox access. The shared reaper owner routes collected completions
to `finalized` using the scoped session and ticket. A failure emits
`cleanup_failed` and retains ownership until an explicit retry succeeds. Drain
closed inbox frames with a bounded discard budget. Only successful native
quiescence, zero outstanding ingress and consumed notifications permit a
`finalized` event to return the provider task. Deinitialize after that event.
The provider context, connection and receive storage must survive this entire
sequence. A stuck native finalizer cannot be timed out by freeing its context.

The selected behavior follows Axolotl NetherNet's `Session` and `SessionManager`
at the revision in the fixture manifest. Defaults retain its message and receive
byte limits. Shulvyr adds explicit queue, allocation and owner work limits.
Ingress limits and partial-assembly deadlines remain enforced during graceful
disconnect. These resource policies are stricter than the upstream grace path,
which skips its normal queue checks.

## Connection registry and owner scheduling

`Manager(send_capacity, receive_capacity, capacity)` owns a connection pool and
one reaper for its lifetime. Its runtime count limit cannot exceed the compiled
capacity. Pool entries keep connections at fixed addresses. The owner ID must
be nonzero and unique while old session IDs or cleanup tickets can exist.
Slot reuse increments generation, and exhausted generations retire the slot.
Use scoped manager methods for owner operations. `get` borrows a connection
until explicit retirement, so callback bindings can retain its inbox without
moving it or looking up owner state on a native thread.

Call `admit` before creating a provider. It validates configuration, checks count
and byte admission, allocates disjoint receive buffers and reserves native
cleanup capacity. No open event is delivered until the ID is registered. Failed
admission leaves no native resource to clean up. Attach the provider before
publishing callbacks, as with a standalone connection.

The aggregate payload reservation for each admitted connection is:

```text
reliable receive storage + unreliable receive storage
+ maximum incoming copied bytes + maximum retained outgoing payload bytes
```

Reliable storage uses the configured message limit. Unreliable storage uses
the smaller of that limit and one frame's payload. Admission checks overflow
and the aggregate limit before allocation. This is a conservative reservation
for application payload storage, including idle connections. It excludes pool
metadata, allocator overhead, provider contexts, native queues and transport
control traffic. Pool metadata is allocated once at the bounded count limit.
Reported native buffering still has each connection's separate outbox limit.
This policy does not establish a total process or native-memory ceiling.

`beginTick` takes an increasing owner tick, monotonic time, shared sender scratch
and explicit quotas. Connection visits include empty slots and advance a
persistent round-robin cursor. Each visited connection gets the supplied
per-connection budget. Scratch preflight checks every live receive buffer,
outbound snapshot and manager/reaper metadata before any provider call. This
scan is bounded by the configured pool and compiled send capacities, independent
of the visit quota. Only a connection updated in the current tick can consume
application input. Negotiation, assembly and grace deadlines are observed on
its next scheduled update, so a small visit quota can delay that observation.

`nextEvent(allow_input)` has a separate round-robin cursor, event quota and
slot-visit quota shared across the tick. A false argument reads no application
frame, including partial fragments. It still delivers open, receipt, close,
cleanup-failure and finalized events. Native results are collected and routed
by the manager even when input is paused. Repeated pulls cannot reset a
connection's frame, byte or 64-message quota. Message views expire on the next
manager mutation. Processing an open or message may immediately disconnect its
connection, which subsequent pulls observe before reading more input.

A finalized event returns the quiesced provider task once. Handle that task
before calling `retire(id)`, which frees receive storage and releases count and
payload reservations. Those credits remain charged through pending events,
queued frames and leases, even when the reaper has finished. Native contexts
must live outside reclaimed pool entries and outlive every callback barrier.
Stale IDs reject before touching a replacement connection.

`requestStop` refuses admission, closes existing connections and stops new reaper
reservations. Keep ticking, consuming control events, retrying failed cleanup
and explicitly retiring connections. `join` refuses while any entry remains,
and `tryJoin` supports owner polling. Deinitialize after joining the worker.
Provider creation, signaling and the standalone server runner remain separate
integration boundaries.

## Verification

The [fixture manifest](../src/transport/fixtures/manifest.json) binds the generator,
exact oracle revision and synthetic outputs. The generator invokes the real
public `Segmenter` and `Assembler` methods. The LGPL oracle is development-only,
and its source/runtime is not shipped in the Zig package. No wire fixture is
produced by the Zig codec. Reproduce it with a clean oracle checkout:

```sh
php tools/generate_framing_fixtures.php PATH_TO_NETHERNET
python tools/check_framing_fixtures.py
zig build test --summary all
```

Tests cover send/receive oracle cases, full-size frame hashes, binary payloads,
retry without commit, aliasing, malformed frames, exact byte/time limits, stale
generations, independent channels and closure. Receipt fixtures call the real
upstream `Session` with its own `FakePeerTransport` and `FakeMessageChannel`
classes, feeding controlled buffered amounts through the public receipt API.
Seven lifecycle fixtures also call public send, disconnect, update and receipt
methods on that real session. They cover drain, grace expiry, empty-message
control buffering, repeated disconnect and closed/failed transports. The
generator reads the public packet quota constant, without claiming to exercise
the PHP manager's scheduling or callbacks.
No PHP test classes or runtime are included in the Zig package. Outbox tests
also cover allocation failures, queue wrap, completion pressure, shared native
admission, bounded pump work, partial-send failure and stale providers. The
Inbox tests cover concurrent channel producers, immutable copies, lease
accounting, repeated acceptance, stale identities, negotiation retry, sticky
failure, allocation faults and stop during an in-flight allocation. The
Reaper tests cover actual worker execution, reservation/result pressure, failed
finalizer retry, shutdown admission, stale tickets, generation exhaustion and
allocation failures. Connection tests additionally cover event ordering, graceful deadlines, the
64-message quota, held ingress credits, scope/clock rejection, provider cleanup
retry and allocation faults. Manager tests cover aggregate admission before allocation, credit retention,
registered opens, input backpressure, round-robin fairness, per-tick quotas,
cross-connection aliasing, stale scopes, generation exhaustion, allocation
faults and shutdown with a held finalizer. They verify Shulvyr's resource and
scheduling contracts. The upstream PHP manager is covered by source review and
its packet quota constant in the fixture generator. The
[native probe](native-transport.md) routes copied frames through the same core
and cancels a partial assembly before closing native connections. Native queue
memory, real client signaling and authenticated gameplay remain separate gates.
