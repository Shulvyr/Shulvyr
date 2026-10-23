# Native WebRTC adapter and probe

The optional `webrtc` module adapts libdatachannel's C API to the core connection
manager. The loopback probe uses that same adapter. The standalone server still
has no native runtime dependency, signaling endpoint, authentication or game
packets. Native integration remains a candidate pending the production gates below.

## Reference and scope

Mojang's [NetherNet guide](https://mojang.github.io/bedrock-protocol-docs/guides/nether-net-onboarding-guide/)
describes full ICE without trickle candidates, UDP candidates and two data
channels. `ReliableDataChannel` is ordered and reliable. `UnreliableDataChannel`
is unordered with zero retransmissions. The probe checks those channel settings
and exchanges synthetic binary payloads over loopback through the core
[framing and session contracts](transport.md). They are not Bedrock packets.

The [v1.26.51 protocol release](https://github.com/Mojang/bedrock-protocol-docs/releases/tag/v1.26.51)
is the stable documentation candidate for protocol 2193. Its tag resolves to
`8667debe0adad27de6c692c88942c489a1193206`. The release's `metadata.zip` has SHA-256
`a364a6f6a4ff3da35e564f94a5089c74703df6fa6bd6bed8555d364c9d9b207f`.
Its Login and NetworkSettings schemas report `x-minecraft-version` as
`1.26.51-beta.1`, `x-protocol-version` as 2193 and `x-format-version` as
`MISSING VERSION`. The release label and schema label differ. The documentation
portal's default preview is a separate target. None of these labels proves a
working connection from a released client.

The [registry snapshot](registries.md#data-provenance) is also separate. Its
source labels protocol 2168. It must not be treated as a complete protocol 2193
data set without checking the required packet definitions and data changes.

## Adapter contract

The optional build module lives in [webrtc.zig](../src/transport/webrtc.zig).
`Peer(receive_capacity, discovery_capacity)` keeps one native peer, its channel
bindings and a bounded discovery queue at a fixed address. It borrows the scoped
manager inbox. `bind` transfers the sink and finalizer into the manager before
`start` creates native objects. A failed start still requires manager-driven
finalization. Keep the context alive through its returned finalized task.

The owner calls `poll` with a discovery quota before updating the manager. It
validates exact labels, empty protocol and channel reliability before reporting
channel opens. Callback failures use sticky inbox stop reasons, preserving drain
receipts before logical closure. Polling and description operations refuse native
access once the core has submitted cleanup, including before the worker starts.
Callbacks copy only admitted frames and never access owner session state.

The local native message ceiling covers both configured send/receive frames and
the two channels' DCEP control messages. Even a 17-byte application-frame policy
needs the 33-byte OPEN message for `UnreliableDataChannel`. The receive callback
still enforces its own application limit. Before publishing an open channel,
the adapter lowers its outbox frame ceiling to `rtcMaxMessageSize` when needed.
It never raises operator limits or changes queued messages. Tests negotiate a
128-byte sender ceiling down to a 64-byte peer limit and deliver a 64-byte
payload in two fragments through the real native library.
The C API reports zero-valued lifetime and retransmission options without their
optional-field presence. It cannot distinguish a zero-lifetime channel from
zero retransmissions in every remote DCEP case. Strict rejection of that
ambiguity remains a provider gate.

Description APIs use full ICE, bounded caller storage and one local/remote
description exchange. Remote input rejects empty, oversized and embedded-null
strings before native parsing. Local output rejects overlap with the context,
connection metadata or its receive buffers. SDP contains ICE credentials and
must stay out of logs. The caller validates identity and supplies stripped SDP
before starting real negotiation. This adapter does not implement identity policy.

Only the reaper worker deletes native channels and peers. It unregisters peer
callbacks, drains discovered and overflow handles, and preserves each handle
until its deletion succeeds. Failed cleanup retains the context for retry.
Successful finalization requires callback quiescence. Then the owner may call
`deinit` and retire the core connection. Global cleanup remains a separate
management operation with the limitation described below.

The first discovery overflow retains its handle and unsubscribes the native
incoming-channel callback. The pinned implementation permits this through its
recursive callback mutex. If native unsubscription fails and more handles arrive
than can be retained, `untracked_handles` latches. Finalization then always fails
and the context cannot be released. The backend must stop admission and recover
at process level. Native resource caps and this exceptional recovery policy
remain production gates. `retainChannel` is a trusted integration escape hatch
for transferring additional same-peer handles into bounded cleanup storage.

## Reproduce

Use x86_64 Windows or Linux, CPython 3.14, Git, CMake, Perl and the pinned Zig
compiler. Windows requires Visual Studio 2022 or 2026 C++ Build Tools and a
Windows SDK. Visual Studio 2026 needs CMake 4.2 or newer. The script uses
`vswhere` to select the installed supported compiler.
Linux requires Ninja and a C/C++ compiler. The script does not install system
tools or change global configuration.

Install Python generator dependencies in a virtual environment with
`python -m pip install --require-hashes -r tools/native-transport/requirements.txt`.
The requirements pin all transitive packages and hashes for CPython 3.14 wheels
on the two supported platforms.

```sh
python tools/native-transport/build_probe.py
```

Use `--zig PATH` if the compiler is not on PATH. Sources and build outputs must
stay under ignored `work/`. Existing source checkouts must match their exact
revisions and have no local changes. The script fetches only the repositories
and submodules in [sources.json](../tools/native-transport/sources.json), checks
their revisions and verifies the C header's LF Git-blob SHA-256. CRLF checkout
line endings are normalized for this text hash. Other byte changes, including
trailing bytes, are rejected.

The build enables Mbed TLS `MBEDTLS_SSL_DTLS_SRTP` and uses the same installed
configuration headers for libdatachannel. Media, WebSockets and examples are
excluded from this data-channel probe. Upstream libdatachannel tests are built
and run. Their executable returns zero even on individual test failures, so
the script also requires a nonempty summary with every test successful.

Mbed TLS's own test suite is not run here. The native build uses its default
cryptographic configuration with the DTLS-SRTP extension enabled. The build
retains its warning checks. This is not a reduced or audited production TLS
configuration.

The script runs ten native adapter tests and the Zig probe in debug and safe
modes. It checks the adapter test count as well as the probe's result. Native
tests run each time, including after cached compilation. To repeat them after
building the native prefix, supply its absolute path:

```sh
zig build test-native-transport -Dnative-transport-prefix=PATH -Doptimize=safe --summary all
```

It checks three complete peer lifecycles, 384 application payloads and 384
reported-drain receipts. A persistent core Manager registers connections before
binding the provider, with a four-slot pool and aggregate payload reservations.
Payloads pass through its Connection controller, bounded Outbox and FrameSink
adapter, with one pump step per owner iteration to yield between fragments.
They travel in 771 framed messages, including three incomplete assemblies
canceled by the owner. It validates labels, protocol, reliability,
full ICE descriptions, three deletion barriers and three native disconnect
events. A separate connected pair pauses application reads while a fragmented
reliable message arrives. Three frames retain their ingress credits while its
receipt still flows. Resuming input must deliver the exact payload once. It then
requests graceful disconnect immediately after enqueueing another reliable
message. It must report that message's drained receipt before close, preserve
the requested reason and retire without grace expiry. This does not assert
delivery to the remote application.
The manager's reusable Reaper worker finalizes all 42 peer contexts across those
cycles, canceled offers, graceful disconnect and the discovery-overflow case.
Native channels and peers transfer to the worker before deletion, with scoped
result validation before owner retirement. While a real callback is held during
deletion, the owner completes three logical ticks and manager updates per cycle
and observes no finalizer completion. After release, deletion finishes and the
remote peer's closure is observed. Another 16 offers are closed without waiting
for gathering. Separate adapter tests cover immutable callback copies,
queue saturation, text, null buffers, empty/header-only and oversize input,
plus a mismatched native channel ID. A separate connected pair opens five extra
channels against a four-slot discovery queue. The overflowing channel has no
application callbacks installed. Its handle stays owned in an emergency slot
while that peer's discovery callback unsubscribes itself. The owner observes
the sticky failure and closes the logical session. The management worker
deletes the overflow and queued handles. The old overflow handle must reject
queries after finalization.
Each wait has a deadline. The Python runner also bounds subprocess runtime.
The probe uses a separate thread-safe Zig allocator and fails on leaked probe
allocations in both build modes. This does not measure native C++ allocations.

Callbacks use the core Inbox to copy borrowed C frames with scoped session and
channel bindings. Its count and byte limits include in-flight allocation and
owner leases. Saturation fails the probe through a sticky stop reason. Native
channel discovery has its own bounded handle queue. The owner handles channel
IDs, session state, frame reassembly and message validation. Each receive pass
processes at most 16 discoveries and frames combined per peer. A held native
callback must finish before deletion returns. All callback contexts
outlive channel/peer deletion and the blocking `rtcCleanup` call. Never call
cleanup from a callback or wait for owner work from a callback.

The Connection controller closes Session, Inbox and Outbox before submitting
finalization. Callback contexts, discovery queues and copied frames remain alive until the
worker's native deletion barriers complete. Global `rtcCleanup` runs in the
probe's management shutdown phase after per-peer finalization and before pool
entries are reclaimed. This remains development tooling, separate from the
finite server runner.
The same manager reuses pool slots 40 times across these scenarios. Each retired
ID must stop resolving. Count and payload reservations return to zero only after
all finalized events are handled and their connections explicitly retired.

The pinned C API's
[global cleanup](https://github.com/paullouisageneau/libdatachannel/blob/bdc5ff28e9d3b863144c94a677ecf5bf043aaf15/src/capi.cpp#L1987)
logs a timeout internally and returns `void`. It exposes no success status.
Per-handle deletion barriers must quiesce callbacks before global cleanup.
This probe does not inject a global cleanup timeout. A production provider
still needs an observable teardown-failure policy.

Raw upstream logs can contain SDP, ICE passwords and local addresses. They stay
in `work/transport-build/` and are never uploaded by CI. The script prints test
counts, phase results and build diagnostics on failure, keeping raw test output
private. Local `evidence.json` records source revisions,
tool versions, the resulting library hash and passed probe modes.

## Dependency review

The probe pins the inspected libdatachannel default-branch HEAD and the inspected
Mbed TLS 3.6 LTS HEAD. The latter is version 3.6.7. This maintained branch matches
the library's Mbed TLS 3 API and includes the fixes described in the upstream
[DTLS advisory](https://mbed-tls.readthedocs.io/en/latest/security-advisories/mbedtls-security-advisory-2026-07-heap-corruption-early-renegotiation-corrupted-dtls-record/).
The selected CMake files build local sources and generators. They do not download
unrecorded build dependencies. Optional JSON and SRTP submodules are not fetched.

| Component | Source license |
| --- | --- |
| libdatachannel and libjuice | MPL-2.0 |
| usrsctp | BSD-3-Clause |
| plog | MIT |
| Mbed TLS and its build framework | Apache-2.0 OR GPL-2.0-or-later |
| Mbed TLS bundled Everest code | Apache-2.0 |
| Mbed TLS bundled p256-m code | Apache-2.0 OR GPL-2.0-or-later |

The probe uses the Apache-2.0 option for Mbed TLS. Original notices remain in
the downloaded checkouts. No native binary is checked into or shipped with the
Zig package. Selecting a production provider still requires distribution notices,
license policy, callback/session ownership, native queue limits, signaling and
identity validation, failure tests and actual client scenarios. A successful
probe does not close those gates.
