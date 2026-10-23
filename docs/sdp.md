# SDP boundary

`SessionDescription` and `SdpFingerprint` provide bounded, allocation-free views
and writers for the SDP used during NetherNet negotiation. They do not verify
an identity token, authenticate a player or create a native peer. The
[signaling envelope](signaling.md) and [WebRTC adapter](native-transport.md)
have separate contracts.

## Parsing and ownership

`SessionDescription.parse` borrows input bytes and caller-owned line descriptors.
Both must remain immutable while the returned view or its attribute slices are
in use. Parsing preflights total size, line lengths, line count and descriptor
capacity before filling storage. Failure leaves descriptor storage unchanged.
Input cannot overlap that storage.

Default limits are 16,384 input/output bytes, 16,384 bytes per nonempty line and
1,024 nonempty lines. The line limit cannot exceed the reference's 1,024. These
are resource bounds and do not establish client maxima. CRLF, bare CR and LF
separate lines. Empty lines are dropped and other bytes are preserved.

Attributes can be queried at session, media or both scopes. Session scope ends
at the first `m=` line. The structural `validate` method requires exactly one
media section, media attributes `ice-ufrag`, `ice-pwd`, `setup` and
`max-message-size`, one selected fingerprint and one media maximum in the range
2 through 4,294,967,295. Media fingerprints take precedence over session values.
Identity lookup returns the first session-level identity attribute.

Structural validation preserves the reference's presence checks for ICE
attributes, including empty values. It does not establish native SDP validity,
candidate validity or a trusted identity. Embedded nulls remain opaque bytes
here and are refused by the native adapter's description API.

## Fingerprints and output

Fingerprint parsing recognizes case-insensitive `sha-256` and colon-separated
hex, preserving spelling for attribute output and the detached signature payload.
It follows the reference's acceptance of short digests and one final LF in the
standalone syntax parser. SDP parsing has already split line separators before
attribute extraction. `sha256Bytes` separately requires an exact 32-byte digest.
Neither operation proves that a remote certificate matches that digest.

The target-protocol [identity primitives](identity.md) use a separate
`FingerprintPayload` writer covering every fingerprint line. The selected
single-fingerprint helper remains a source-behavior contract.

`write` emits CRLF and a final CRLF into caller storage. A single `Edit` removes
identity, removes candidates and end-of-candidates, rewrites connection addresses,
replaces candidates, limits candidates, or inserts/replaces session identity.
Replacement placement and preserved line order follow the reference. An empty
result is serialized as CRLF. Chain edits by parsing the output into separate
storage.

Writing checks all output limits and the written region's overlap with input,
descriptors, the view and edit arguments before mutation. Failure leaves output
unchanged. Added identity/candidate values must be single lines. This explicit
construction rule prevents line injection and keeps resource accounting defined.
The reference's unrestricted builder methods do not enforce that rule.
Output may contain ICE credentials or identity data and must stay out of logs.

## Independent fixtures

The behavior oracle is Axolotl NetherNet's default-branch revision
[6ecacda](https://github.com/axolotl-pm/nethernet/tree/6ecacdaed3b0605a6a523235e5536f9c09ea56fd/src/sdp).
The generator calls its public `SessionDescription` and `Fingerprint` methods
with synthetic data. Expected bytes are produced by PHP, independently of Zig.
The LGPL-3.0-or-later oracle source and PHP runtime remain outside the Zig package.
Its fixture manifest records the source revision and generator/fixture hashes.

```sh
zig build check-transport-fixtures --summary all
zig build test --summary all
```

Oracle regeneration is optional and lives in
[Shulvyr/reference-tools](https://github.com/Shulvyr/reference-tools).
The Zig checker validates the frozen fixture, manifest and recorded producer
hashes without reading or executing PHP sources.
Building the server and running its tests do not require the reference checkout.

The corpus covers 42 descriptions, 18 edits and 17 standalone fingerprint cases.
Additional tests cover configured resource bounds, storage overlap, unchanged
output on failure and conversion to a concrete certificate digest. These are
codec and source-behavior checks. Identity verification, native interoperability
and real-client negotiation require separate evidence.

The current [go-nethernet parser](https://github.com/df-mc/go-nethernet/blob/215e46422b5831d6ddc6146003617dc3f1ff7c26/conn.go#L502)
also requires one media section, prefers media fingerprints and rejects SCTP
maximums below two. It validates setup roles in that parser.
[Endstone's fingerprint payload](https://github.com/EndstoneMC/nethernet-python/blob/339eb5a65582098af4152f27ed5c855ba205c65d/src/nethernet/identity.py#L77)
collects every fingerprint line, which differs from Axolotl's selected single
fingerprint. These source comparisons inform later negotiation policy and are
not additional runtime interoperability tests.
