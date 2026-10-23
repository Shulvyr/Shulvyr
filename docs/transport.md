# Transport framing and sessions

`framing` and `TransportSession` provide the owner-side boundary between copied
data-channel frames and application messages. They allocate no heap memory.
The native provider, signaling, authentication and Bedrock packet adapters have
separate responsibilities. The server runner does not open a network listener.

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
generations, independent channels and closure. The
[native probe](native-transport.md) routes copied frames through the same core
and cancels a partial assembly before closing native connections. Native queue
memory, real client signaling and authenticated gameplay remain separate gates.
