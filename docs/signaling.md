# Signaling text

`Signal` parses and writes the text envelope used by LAN and message-based
NetherNet signaling. It has no sockets, peer registry, authentication or SDP
validation. The optional [WebRTC adapter](native-transport.md) remains separate.
The HTTP onboarding path has its own request and identity contracts.

## Wire behavior

The selected behavior reference is Axolotl NetherNet's default-branch revision
[6ecacda](https://github.com/axolotl-pm/nethernet/blob/6ecacdaed3b0605a6a523235e5536f9c09ea56fd/src/signaling/Signal.php).
The parser recognizes `CONNECTREQUEST`, `CONNECTRESPONSE`, `CANDIDATEADD` and
`CONNECTERROR`. The first two literal spaces separate kind, connection ID and
opaque data. Empty data, extra spaces and arbitrary data bytes are preserved.

Connection IDs use the leading decimal digits of the second field. Leading
zeroes normalize to a `u64` value and a trailing suffix is ignored. Signs, a field
without initial digits and overflow are rejected. Writing emits the canonical
decimal ID and preserves the data bytes.

The [go-nethernet parser](https://github.com/df-mc/go-nethernet/blob/215e46422b5831d6ddc6146003617dc3f1ff7c26/signal.go)
also accepts decimal prefixes. It additionally validates `CONNECTERROR` data as
a signed error code. Shulvyr follows Axolotl's text-envelope behavior here and
leaves payload validation to the negotiation layer. Parsing an envelope does
not authorize a connection or establish valid SDP, candidates or error codes.

## Bounds and ownership

`Limits` defaults to 65,535 total text bytes and 16,384 data bytes. The caller may
set smaller limits, including zero data bytes. A zero text limit or a data limit
greater than the text limit is invalid. Oversized text is rejected before scans.
These are operator resource bounds, not inferred client maxima.

Parsing allocates no memory and returns a data slice borrowed from its input.
Copy it before queuing or retaining it past that input's lifetime. Writing uses
caller-owned storage, checks the full size before mutation and rejects overlap
with the signal or its borrowed data. A failed write leaves output unchanged.
SDP and ICE candidates can contain credentials. Keep signaling text out of logs.

## Independent fixtures

Thirty synthetic cases come from the public PHP `Signal::parse` and `toString`
methods at the revision above. The development-only LGPL-3.0-or-later oracle's
source and PHP runtime are not included in the Zig package. The generator
requires a clean reference checkout at that exact revision. Zig does not produce
the checked-in expected bytes.

```sh
php tools/generate_signaling_fixtures.php PATH_TO_NETHERNET
python tools/check_signaling_fixtures.py
zig build test --summary all
```

The manifest records source provenance, generator and fixture hashes. Cases
cover all four kinds, unsigned limits, decimal suffixes, leading zeroes,
arbitrary data bytes, empty data, malformed fields and canonical output.
Separate tests exercise configured bounds and unchanged output on failed writes.
These are codec checks. No real Minecraft client or signaling listener is tested.
