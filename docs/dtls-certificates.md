# DTLS certificates and SDP binding

`DtlsCertificate` owns an ephemeral P-256 key and a self-signed X.509 v3
certificate. Generation, SHA-256, ECDSA and PEM encoding use Zig and its standard
library. No external process, CA service or certificate file is needed.
The persistent P-384 [operator key](operator-keys.md) remains separate.

WebRTC requires P-256 support in
[RFC 8827](https://www.rfc-editor.org/rfc/rfc8827.html#section-6.5).
Self-generated certificates identify the transport key through the signaled
fingerprint, as described in
[RFC 5763](https://www.rfc-editor.org/rfc/rfc5763.html#section-5).
They do not establish an HTTPS identity or a public CA trust chain.

## Certificate owner

`generate` takes a caller-supplied Unix time and a lifetime. The default lifetime
is one day, with a hard maximum of 30 days. Times must be nonnegative and remain
within year 9999. Validity uses UTCTime through 2049 and GeneralizedTime from
2050, following [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html#section-4.1.2.5).
The certificate has a random positive 16-byte serial, equal issuer/subject names,
an ECDSA/SHA-256 signature, critical CA:false basic constraints and critical
digitalSignature key usage. DER is bounded to 512 bytes.

The owner contains private material. Do not copy it or use it concurrently.
`deinit` clears owned storage and further operations fail. Explicit `{f}`
formatting is redacted, while structural dumps and raw fields can expose keys.
The public DER view borrows the owner. Its fingerprint hashes the entire DER
certificate, unlike the operator pin that hashes SPKI.

PEM exports use bounded caller buffers, include a trailing sentinel and preserve
output on failure. They reject overlap with the owner. Private export is
unencrypted PKCS#8 with a named P-256 curve, scalar and uncompressed public point.
Including the public point lets the pinned provider import it without computing
that point through its null RNG callback. Clear every exported private buffer
after a synchronous consumer has copied it.

## Provider binding

The optional native `Peer.start` generates a fresh certificate in Zig.
`startWithCertificate` instead borrows an existing owner for the synchronous
constructor call. Both supply in-memory PEM to the pinned provider, retain the
public fingerprint and validity, and clear Zig's temporary key PEM. The native
constructor copies its configuration and imports the pair before returning.
Its private copies remain inside the native peer until deletion. This does not
provide isolation from native code or prove physical erasure of native copies.

`writeLocalDescription` reads the actual fully gathered native SDP, validates
its structure and requires every session/media SHA-256 fingerprint to match
the configured certificate. It checks certificate validity again before native
access. A mismatch or expired certificate is an error. Raw output may change on
failure and contains ICE credentials, so it must stay out of logs.

`writeSignedLocalDescription` obtains that same validated native description
and signs it with the operator key through `SignedDescription`. It accepts no
caller-supplied local SDP. Output is unchanged on failure. Workspace can change
and contains the raw description and assertion. Keep both buffers private.
Admission policy, remote service tokens and game login remain separate gates.

## Evidence

Core tests parse the generated certificate with the standard certificate parser,
verify its self-signature and validity, check PEM/key agreement, malformed time
parameters, output preflight, destruction and all-scope fingerprint matching.
Native tests clear the caller's certificate after import, then verify both
operator signatures over the actual local SDP. They refuse a substituted
local pin, preserve cleanup ownership after a failed import and reject a real
DTLS handshake with an altered remote fingerprint. The rejection test observes
both the native verifier's rejection and the adapter's sticky failure.

The loopback probe uses generated certificates for its existing traffic and
lifecycle scenarios. These are native integration checks. Real Minecraft
client negotiation and production certificate policy have not been tested.
