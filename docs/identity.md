# Transport identity primitives

`IdentityAssertion` parses the NetherNet identity envelope and checks detached
ES384 proofs using Zig's standard-library P-384/SHA-384 implementation.
`IdentityPublicKey` reads public keys from an EC/P-384 JWK or a base64 DER
SubjectPublicKeyInfo. No additional runtime library is required.

`OperatorKey` owns a P-384 operator key. `IdentityIssuer` creates self-signed
server assertions and `SignedDescription` binds them to local SDP fingerprints.
[Operator key storage](operator-keys.md) persists keys and supplies explicit
initialization, inspection, rotation, recovery and backup commands. These
primitives do not admit a player or validate a Minecraft service token. The
server runner has no identity negotiation flow yet.

## Ownership and resource limits

`IdentityAssertion.parse` takes an allocator, the session-level `a=identity`
value and explicit limits. It validates the encoded length before allocation,
then makes one allocation for retained bytes and JSON storage. The returned
owner may move. Keep it alive and immutable while using its domain, token or
JSON views. Do not duplicate the owner or call `deinit` twice. Input can be
released after parsing. Failed parsing releases the allocation. Owned storage
is cleared before being returned to the allocator. The public key and proof
signature are owned inline in the returned structure.

Defaults limit the encoded attribute to 16 KiB, compact JWT to 12 KiB, each
decoded JSON document to 16 KiB, nesting to eight levels, aggregate scanner
tokens to 512 and aggregate base64 output to 32 KiB. The storage budget is
128 KiB and the fingerprint payload limit is 16 KiB. Configurations have hard
caps, including 1 MiB of storage, 32 nesting levels and 4,096 scanner tokens.
These are resource policies, not measured client maxima. A future negotiator
must reserve aggregate capacity and deadlines before calling this parser.

The outer value is standard-base64 JSON. Its `idp.protocol` must be `default`
and its domain nonempty. `assertion` contains another JSON document as a string.
That document carries the compact `token` and detached `fingerprints` JWS.
The token's `cpk` provides a P-384 public key. `x5u`, issuer strings and other
claims remain untrusted data. No field triggers a URL fetch or key lookup.

## Separate checks and trust

- Parsing validates structure and the detached proof's ES384 header and
  96-byte JOSE signature representation. It does not verify either signature.
- `verifyFingerprint` checks the detached JWS over a caller-supplied canonical
  payload using `cpk`. Its base64url hashing is streamed with fixed scratch
  space. This proves possession of that key for those payload bytes.
- `token.verifyEs384` checks the JWT with an explicitly supplied P-384 key.
  Passing its own `cpk` checks a self-signature. It does not establish a trusted
  issuer or authorize claims. RS256 service-token verification is not implemented.
- `token.checkTimestamps` uses caller-supplied Unix time and nonnegative leeway.
  It follows the source's optional `exp`, `nbf` and `iat` checks, including
  truncation of finite fractional timestamps toward zero. Arithmetic uses i128
  to avoid overflow at i64 clock boundaries. Missing timestamps are accepted
  by this primitive. An admission policy must impose its required claims.

A token with forged claims can still contain a public key whose owner signed
the fingerprint proof. Tests preserve this distinction. Online admission needs
trusted service keys, issuer/audience policy, token validation and binding to
the later game login. Anonymous and self-signed modes need explicit policies.
No successful primitive call is a substitute for those decisions. Keep tokens,
assertions and SDP out of logs.

## Fingerprint payload and encoding policy

`FingerprintPayload.write` collects every SDP fingerprint attribute in wire
order, across session and media scopes. It emits compact canonical JSON with
`algorithm` before `digest`, preserving their spelling. It requires concrete
32-byte SHA-256 digests. Defaults allow 16 fingerprints and 16 KiB of output.
The writer allocates nothing and preserves output on size, count, syntax or
alias failure. The description and its borrowed data must remain immutable.

This follows the current
[Mojang assertion guide](https://github.com/Mojang/bedrock-protocol-docs/blob/4fbe153e04e56645addc681259e398b94c60d14f/additional_docs/NetherNetOnboardingGuide.md#51-validating-the-client-assertion-in-the-offer).
It is separate from the [source-behavior fingerprint helper](sdp.md), which
selects one fingerprint and preserves the reference's short-digest syntax.
The relevant formats are [JWS](https://www.rfc-editor.org/rfc/rfc7515),
[JWK](https://www.rfc-editor.org/rfc/rfc7517) and
[JWT](https://www.rfc-editor.org/rfc/rfc7519).

Intentional input boundaries are stricter than Axolotl's general PHP/OpenSSL
parsers. JSON object fields must be unique. Base64 accepts padded or unpadded
encodings with canonical pad bits, without whitespace or a mixed alphabet.
SPKI requires canonical named-curve DER with a compressed or uncompressed
P-384 point and no trailing bytes. JWK private `d` fields are rejected.
Unsupported `crit` and `b64` protected headers are refused when checking ES384.
Malformed proof structure is rejected during parsing. Nonfinite or out-of-range
timestamps are refused instead of using PHP's platform-dependent casts.

The original SPKI bytes determine a public key's digest and equality, matching
the reference. Compressed and uncompressed SPKI can describe the same point
and have different digests. JWK input produces uncompressed canonical SPKI.
Future pin storage must choose and document its representation contract.

## Operator keys and server assertions

An `OperatorKey` owns its private scalar until `deinit` clears its storage.
Generate it once for an operator lifetime with the caller's `std.Io` CSPRNG.
Do not duplicate the owner. Serialize signing, export and destruction in its
owner context. Operations after destruction fail. Explicit formatting with
`{f}` is redacted, but structural dumps and raw fields can still disclose the key.

`fromSecretScalar` copies a canonical nonzero 48-byte big-endian scalar.
`writeSecretScalar` explicitly exports those sensitive bytes to caller storage.
The caller must protect and clear import/export buffers. Importing the same
scalar restores the same public key. This is a serialization boundary, without
filesystem permissions, backup or crash recovery. `OperatorKeyStore` adds an
owned append/flush boundary and explicit recovery around this scalar format.
Its command and storage contracts are described in [operator keys](operator-keys.md).

`IdentityIssuer.write` borrows the key and uses fresh CSPRNG noise for two ES384
signatures. The JWT carries `iat`, `exp` and `cpk`. JWK is the default required
by the target protocol guide. `legacy_der` is an explicit reference-format
option. Issuance always presents uncompressed canonical SPKI/JWK coordinates,
even when an external key provider supplies a compressed public key. Renewing
the token preserves that key identity. The `x5u` header contains its base64 DER,
without fetching a URL. The caller supplies Unix time, a positive lifetime and
the display domain. Expiry arithmetic rejects overflow.

`writeSigned` accepts a synchronous signer with `sign(input) ![96]u8`. The signer
must return raw ES384 bytes for the supplied public key and must not retain or
mutate input or caller buffers. Both signatures are verified before publication.
This boundary can support another key store without exposing its internals.

Issuance uses caller output and workspace, with no heap allocations. Defaults
allow a 16 KiB encoded attribute, 256-byte UTF-8 domain and 16 KiB proof payload.
Hard caps are 64 KiB, 1,024 bytes and 16 KiB respectively. Preflight rejects
invalid configuration, overlapping buffers and insufficient output/workspace
before invoking the signer. Every failure preserves output. Workspace may
change, and a signing failure may follow an earlier successful signer call.
Keep both buffers out of logs.

## Binding a local description

`SignedDescription.write` takes an immutable parsed local SDP, an operator key,
caller output and workspace. It collects all fingerprint attributes across all
scopes, signs their canonical payload and inserts one session identity before
the first media section. Existing identity attributes in every scope are removed.
Fingerprint spelling and order remain unchanged. Output uses CRLF line endings.

The description, payload and identity limits remain explicit. This wrapper caps
SDP text at 64 KiB and fingerprint payloads at 16 KiB. Description limits apply
to normalized input and signed output. Workspace reserves the configured SDP,
fingerprint and identity capacities, then gives the remaining tail to issuance.
Tests use 128 KiB with default limits. Exhaustion is an explicit error.
Overlaps with the key, domain, source lines or descriptors are
rejected before workspace writes. It stages the complete result before copying
to output, so failure preserves output. Workspace may change and output-size
or expansion errors may occur after signing.

The input must come from the caller's local negotiation flow. This helper does
not create an SDP answer, validate ICE/DTLS or prove that a fingerprint matches
the actual transport certificate. Those checks and a durable operator key are
required at the provider and negotiation boundaries before accepting clients.

## Independent evidence

The optional generator calls public APIs from current Axolotl NetherNet
[6ecacda](https://github.com/axolotl-pm/nethernet/tree/6ecacdaed3b0605a6a523235e5536f9c09ea56fd/src/identity).
It produces 12 key cases, 26 assertion/proof cases and 15 timestamp cases.
Keys exist only during generation and are not exported. Regeneration creates
fresh synthetic public keys and randomized signatures. The committed fixture
is frozen by source, generator and output hashes. Its expected wire bytes and
signature results are independent of the Zig implementation.

```sh
zig build check-fixtures --summary all
zig build test --summary all
```

The generators are maintained in
[Shulvyr/reference-tools](https://github.com/Shulvyr/reference-tools).
PHP with OpenSSL is needed only in its optional regeneration workflow.
Core tests and the Zig fixture checker consume committed evidence and the local
producer snapshot without that runtime or source checkout. Cryptographic
vectors around base64 chunk boundaries exercise the
streaming verifier, including empty and non-SDP payloads. Those vectors are
primitive tests, not valid protocol messages or real-client evidence.

The separate issuance corpus has eight cases from the same pinned public APIs.
It covers JWK and legacy DER, escaping, clock/lifetime boundaries and multiple
fingerprints. Its test signer replays a recorded valid signature only when the
complete signing input matches the source bytes. This checks serialization,
without retaining a private fixture key. Separate tests use real Zig signing,
invalid and wrong-key signers, key destruction, token renewal and SDP binding.
The optional generator adds no runtime dependency or normal-build requirement.

Additional tests cover ownership, allocation failure, byte/depth/token/storage
budgets, duplicate fields, wrong keys, malformed algorithms, forged claims,
timestamp overflow and unchanged output on failure. Real-client identity
negotiation and integration with the native WebRTC adapter remain untested.
