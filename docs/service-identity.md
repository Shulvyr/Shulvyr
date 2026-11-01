# Service token verification

`ServiceIdentity.verify` verifies a client transport assertion with a
caller-authenticated `ServiceKeys` snapshot. It checks the RS256 token signature,
exact issuer and audience, expiry, optional `nbf`/`iat`, subject and detached
ES384 proof over every SDP fingerprint. The result owns its subject, client key,
token expiry and key-snapshot generation. It retains no borrowed token or SDP.

This is a verification boundary. It does not fetch trusted keys, admit a player,
check game permissions or bind a later game login to this identity. The server
runner still has no online admission flow.

## Authority and key lifecycle

The management caller supplies JWKS bytes, expected issuer/audience, a validity
window and a nonzero generation. It must authenticate the key source before
calling `ServiceKeys.load`. Parsing public JSON cannot establish that authority.
The snapshot copies its strings and key IDs into one owned allocation. Input
may be released after loading. Keep the snapshot immutable and alive until its
synchronous readers return. Do not duplicate it or destroy it during a read.

The current Minecraft
[OpenID metadata](https://authorization.franchise.minecraft-services.net/.well-known/openid-configuration)
publishes RS256 and issuer `https://authorization.franchise.minecraft-services.net/`.
The multiplayer audience `api://auth-minecraft-services/multiplayer` is used by
[BedrockDebugProxy's verifier](https://github.com/NhanAZ/BedrockDebugProxy/blob/4cdf1be525440abb10e8cd1e6ac54c04fae9e066/third_party/gophertunnel/minecraft/service/token.go).
These inform configuration, they are not implicit trust anchors in the parser.
Never select a provider URL from an untrusted `idp`, `jku`, `jwk` or `x5u` field.

A snapshot has an explicit validity window of at most one day. Verification
refuses a future, expired or destroyed snapshot. Unknown `kid` values fail
without network access or a fallback key. The caller handles refresh, publication
and retirement. New asynchronous results must carry the snapshot generation so
the owner can reject results from a replaced authority.
Recheck the current snapshot's validity and token expiry before applying a
queued result.

## Supported profile and bounds

RSA JWKs use canonical unpadded base64url unsigned integers. Supported key sizes
are 2048, 3072 and 4096 bits, with odd exponents greater than two and at most
32 bits. Private JWK fields are refused. Optional `alg`, `use` and `key_ops`
must permit RS256 signature verification. Missing `alg` is allowed because the
authority fixes the algorithm. Duplicate key IDs and duplicate JSON fields fail.

Default JWKS limits are 32 KiB of input, eight keys, eight nesting levels,
2,048 scanner tokens and 128 KiB of storage. Hard caps are 64 KiB, 16 keys,
16 levels, 4,096 tokens and 256 KiB. Key IDs are bounded to 128 bytes and authority
strings to 512 bytes. Exhaustion returns an error. The snapshot does not retain
an older successful load on behalf of the caller.

Only RS256 JWTs and ES384 detached proofs are accepted here. JWT signatures
must have the exact selected modulus width. Critical or unencoded-payload
extensions are unsupported. Token headers cannot supply replacement keys.
The original compact signing input is verified before claims are trusted.

Issuer comparison is exact. Audience may be a string or a list of at most
16 strings, each bounded to 512 bytes. `exp` and nonempty `sub` are required.
This profile requires nonnegative whole-second NumericDates and a subject of
at most 256 UTF-8 bytes without control characters. Optional `nbf` and `iat`
must precede expiry. Default clock leeway is 30 seconds, capped at 300 seconds.
Arithmetic uses i128 at i64 clock boundaries. These stricter timestamp rules
are separate from the legacy [identity primitive](identity.md) behavior.

Proof verification covers every session/media fingerprint with the existing
canonical payload writer. It is bounded to 16 fingerprints and 16 KiB. Caller
workspace must not overlap the assertion, SDP or key-snapshot owners. Workspace
may change on failure. Keep tokens and identity data out of logs. Explicit
formatting of the verified result is redacted, while structural dumps can still
expose personal data.

## Independent evidence

The checked-in synthetic corpus contains 26 cases produced by the Zig
[Windows CNG oracle](https://github.com/Shulvyr/reference-tools).
CNG generates ephemeral keys, hashes signing inputs, signs and verifies both
signature types. The generator imports no Shulvyr verifier code and exports
no private keys. Its published source hash and corpus digest are checked by
`zig build check-fixtures`. Regeneration is optional and requires Windows.
Ordinary server builds and tests use Zig and local data on Windows or Linux.

Tests cover all three RSA sizes, issuer/audience/time errors, unknown keys,
algorithm confusion, an attacker key embedded in the header, wrong proof keys,
shadowed media fingerprints, malformed key material, snapshot lifetime,
allocation failure and owned verification results. Synthetic vectors do not
prove live Minecraft token or client compatibility.
