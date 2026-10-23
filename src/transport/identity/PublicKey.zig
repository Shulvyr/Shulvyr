const std = @import("std");
const codec = @import("codec.zig");
const PublicKey = @This();
pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const identifier = "\x30\x10\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x05\x2b\x81\x04\x00\x22";
const prefix = "\x30\x76" ++ identifier ++ "\x03\x62\x00";

// The original canonical SPKI is retained for the reference's key digest.
// Compressed and uncompressed point encodings can name the same curve point
// while producing different DER digests. No private key material is retained.
encoded: [120]u8,
encoded_length: u8,
key: Ecdsa.PublicKey,

pub fn fromDer(der: []const u8) !PublicKey {
    if (der.len != 72 and der.len != 120) return error.InvalidPublicKeyEncoding;
    if (der[0] != 0x30 or der[1] != der.len - 2 or !std.mem.eql(u8, der[2..20], identifier) or
        der[20] != 0x03 or der[21] != der.len - 22 or der[22] != 0) return error.InvalidPublicKeyEncoding;
    const point = der[23..];
    if ((point.len == 97 and point[0] != 4) or (point.len == 49 and point[0] != 2 and point[0] != 3)) return error.InvalidPublicKeyEncoding;
    const key = Ecdsa.PublicKey.fromSec1(point) catch return error.InvalidPublicKeyPoint;
    key.p.rejectIdentity() catch return error.InvalidPublicKeyPoint;
    var result: PublicKey = .{ .encoded = @splat(0), .encoded_length = @intCast(der.len), .key = key };
    @memcpy(result.encoded[0..der.len], der);
    return result;
}

pub fn fromBase64Der(encoded: []const u8) !PublicKey {
    if (encoded.len > 256) return error.IdentityBytesLimit;
    var buffer: [120]u8 = undefined;
    return fromDer(try codec.decode(&buffer, encoded, false));
}

pub fn fromClaim(claim: codec.Value) !PublicKey {
    if (claim == .string) return fromBase64Der(claim.string);
    if (!std.mem.eql(u8, try codec.text(try codec.field(claim, "kty")), "EC") or
        !std.mem.eql(u8, try codec.text(try codec.field(claim, "crv")), "P-384")) return error.UnsupportedPublicKey;
    if (claim.object.contains("d")) return error.PrivateKeyClaim;
    var point: [97]u8 = undefined;
    point[0] = 4;
    inline for (.{ "x", "y" }, .{ 1, 49 }) |name, offset| {
        const encoded = try codec.text(try codec.field(claim, name));
        if (encoded.len > 66) return error.IdentityBytesLimit;
        const coordinate = try codec.decode(point[offset..][0..48], encoded, true);
        if (coordinate.len != 48) return error.InvalidPublicKeyEncoding;
    }
    var der: [120]u8 = undefined;
    @memcpy(der[0..prefix.len], prefix);
    @memcpy(der[prefix.len..], &point);
    return fromDer(&der);
}

pub fn derBytes(self: *const PublicKey) []const u8 {
    return self.encoded[0..self.encoded_length];
}

pub fn digest(self: *const PublicKey) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(self.derBytes(), &result, .{});
    return result;
}

pub fn equals(self: *const PublicKey, other: *const PublicKey) bool {
    return std.mem.eql(u8, self.derBytes(), other.derBytes());
}

pub fn verify(self: *const PublicKey, input: []const u8, signature: []const u8) !void {
    if (input.len > 64 * 1024) return error.IdentityBytesLimit;
    var verifier = try self.startVerifier(signature);
    verifier.update(input);
    verifier.verify() catch return error.IdentitySignatureMismatch;
}

pub fn startVerifier(self: *const PublicKey, signature: []const u8) !Ecdsa.Verifier {
    if (signature.len != Ecdsa.Signature.encoded_length) return error.InvalidIdentitySignatureLength;
    const value = Ecdsa.Signature.fromBytes(signature[0..96].*);
    return value.verifier(self.key) catch return error.IdentitySignatureMismatch;
}
