const std = @import("std");
const Certificate = @import("identity/DtlsCertificate.zig");
const Binding = @import("sdp/CertificateBinding.zig");
const Description = @import("sdp/SessionDescription.zig");
const testing = std.testing;
const io = testing.io;
const now = 1792756800;

fn parsed(certificate: *const Certificate) !std.crypto.Certificate.Parsed {
    return (std.crypto.Certificate{ .buffer = try certificate.derBytes(), .index = 0 }).parse();
}

test "DTLS certificate has a valid self-signature and full DER fingerprint" {
    var certificate = try Certificate.generate(io, .{ .now = now });
    defer certificate.deinit();
    const decoded = try parsed(&certificate);
    try decoded.verify(decoded, now);
    try testing.expectEqualStrings("Shulvyr DTLS", decoded.commonName());
    try testing.expectEqual(now, decoded.validity.not_before);
    try testing.expectEqual(now + 86400, decoded.validity.not_after);
    try testing.expectEqual(std.crypto.Certificate.NamedCurve.X9_62_prime256v1, decoded.pub_key_algo.X9_62_id_ecPublicKey);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try certificate.derBytes(), &digest, .{});
    try testing.expectEqualSlices(u8, &digest, &(try certificate.fingerprint()));
    var changed = certificate.der;
    changed[certificate.der_length - 1] ^= 1;
    const damaged = try (std.crypto.Certificate{ .buffer = changed[0..certificate.der_length], .index = 0 }).parse();
    try testing.expectError(error.CertificateSignatureInvalid, damaged.verify(damaged, now));
}

test "DTLS certificate PEM and PKCS8 carry the matching P256 key" {
    var certificate = try Certificate.generate(io, .{ .now = now });
    defer certificate.deinit();
    var public_buffer: [Certificate.max_certificate_pem_bytes]u8 = undefined;
    const public = try certificate.writeCertificatePem(&public_buffer);
    try testing.expect(public[public.len] == 0);
    var private_buffer: [Certificate.max_private_key_pem_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &private_buffer);
    const private = try certificate.writePrivateKeyPem(&private_buffer);
    try testing.expect(private[private.len] == 0);
    var encoded: [192]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, private, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '-') continue;
        @memcpy(encoded[count..][0..line.len], line);
        count += line.len;
    }
    var der: [138]u8 = undefined;
    defer std.crypto.secureZero(u8, &der);
    try std.base64.standard.Decoder.decode(&der, encoded[0..count]);
    var key = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.fromSecretKey(.{ .bytes = der[36..68].* });
    defer std.crypto.secureZero(u8, &key.secret_key.bytes);
    const decoded = try parsed(&certificate);
    try testing.expectEqualSlices(u8, decoded.pubKey(), &key.public_key.toUncompressedSec1());
    try testing.expectEqualSlices(u8, decoded.pubKey(), der[73..138]);
}

test "DTLS certificate time limits include the UTC to GeneralizedTime boundary" {
    var certificate = try Certificate.generate(io, .{ .now = 2524607990, .lifetime_seconds = 20 });
    defer certificate.deinit();
    const decoded = try parsed(&certificate);
    try decoded.verify(decoded, 2524608000);
    try testing.expectEqual(@as(u64, 2524607990), decoded.validity.not_before);
    try testing.expectEqual(@as(u64, 2524608010), decoded.validity.not_after);
    try certificate.validateTime(2524608010);
    try testing.expectError(error.CertificateExpired, certificate.validateTime(2524608011));
    try testing.expectError(error.CertificateNotYetValid, certificate.validateTime(2524607989));
    for ([_]Certificate.Parameters{ .{ .now = -1 }, .{ .now = now, .lifetime_seconds = 0 }, .{ .now = now, .lifetime_seconds = 30 * 86400 + 1 }, .{ .now = 253402300790, .lifetime_seconds = 10 }, .{ .now = std.math.maxInt(i64) } }) |parameters| {
        // Unexpected successful owners are cleared without formatting secrets.
        if (Certificate.generate(io, parameters)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedCertificateLifetimeFailure;
        } else |err| try testing.expect(err == error.InvalidCertificateLifetime);
    }
}

test "DTLS certificate exports reject overlap and short outputs before writes" {
    var certificate = try Certificate.generate(io, .{ .now = now });
    defer certificate.deinit();
    var short: [15]u8 = @splat(42);
    try testing.expectError(error.NoSpace, certificate.writePrivateKeyPem(&short));
    try testing.expectError(error.NoSpace, certificate.writeCertificatePem(&short));
    try testing.expect(std.mem.allEqual(u8, &short, 42));
    try testing.expectError(error.AliasedBuffer, certificate.writePrivateKeyPem(&certificate.der));
    try testing.expectError(error.AliasedBuffer, certificate.writeCertificatePem(&certificate.der));
    const decoded = try parsed(&certificate);
    try decoded.verify(decoded, now);
}

test "DTLS certificate destruction clears ownership and rejects further use" {
    var certificate = try Certificate.generate(io, .{ .now = now });
    certificate.deinit();
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&certificate), 0));
    var output: [768]u8 = @splat(23);
    try testing.expectError(error.DtlsCertificateDestroyed, certificate.derBytes());
    try testing.expectError(error.DtlsCertificateDestroyed, certificate.fingerprint());
    try testing.expectError(error.DtlsCertificateDestroyed, certificate.validateTime(now));
    try testing.expectError(error.DtlsCertificateDestroyed, certificate.writePrivateKeyPem(&output));
    try testing.expectError(error.DtlsCertificateDestroyed, certificate.writeCertificatePem(&output));
    try testing.expect(std.mem.allEqual(u8, &output, 23));
}

const prefix = "v=0\r\na=fingerprint:sha-256 ";
const suffix = "\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=ice-ufrag:abc\r\na=ice-pwd:secret\r\na=setup:actpass\r\na=max-message-size:65536\r\n";
const zeros = "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00";
const ones = "01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01";

test "certificate binding checks every session and media fingerprint" {
    var lines: [64][]const u8 = undefined;
    const valid = try Description.parse(prefix ++ zeros ++ suffix ++ "a=fingerprint:SHA-256 " ++ zeros ++ "\r\n", &lines, .{});
    try Binding.validate(&valid, @splat(0));
    try testing.expectError(error.CertificateFingerprintMismatch, Binding.validate(&valid, @splat(1)));
    const shadowed = try Description.parse(prefix ++ zeros ++ suffix ++ "a=fingerprint:sha-256 " ++ ones ++ "\r\n", &lines, .{});
    try testing.expectError(error.CertificateFingerprintMismatch, Binding.validate(&shadowed, @splat(0)));
    const short = try Description.parse(prefix ++ "AB:CD" ++ suffix, &lines, .{});
    try testing.expectError(error.InvalidDigestLength, Binding.validate(&short, @splat(0)));
    const missing = try Description.parse("v=0" ++ suffix, &lines, .{});
    try testing.expectError(error.MissingFingerprint, Binding.validate(&missing, @splat(0)));
}
