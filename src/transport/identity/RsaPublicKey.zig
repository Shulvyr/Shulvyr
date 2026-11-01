const std = @import("std");
const codec = @import("codec.zig");
const Rsa = std.crypto.Certificate.rsa;
const PublicKey = @This();

key: Rsa.PublicKey,
modulus_bytes: u16,

/// RS256 public-key boundary. Only canonical unsigned JWK integers and
/// 2048/3072/4096-bit moduli are supported. No private key is accepted.
pub fn fromJwk(value: codec.Value) !PublicKey {
    if (!std.mem.eql(u8, try codec.text(try codec.field(value, "kty")), "RSA")) return error.UnsupportedServiceKey;
    for ([_][]const u8{ "d", "p", "q", "dp", "dq", "qi", "oth", "k" }) |name| if (value.object.contains(name)) return error.PrivateServiceKey;
    if (value.object.get("alg")) |algorithm| {
        if (!std.mem.eql(u8, try codec.text(algorithm), "RS256")) return error.UnsupportedServiceKey;
    }
    if (value.object.get("use")) |use| {
        if (!std.mem.eql(u8, try codec.text(use), "sig")) return error.UnsupportedServiceKey;
    }
    if (value.object.get("key_ops")) |operations| {
        if (operations != .array or operations.array.items.len != 1 or !std.mem.eql(u8, try codec.text(operations.array.items[0]), "verify")) return error.UnsupportedServiceKey;
    }
    var modulus: [512]u8 = undefined;
    var exponent: [4]u8 = undefined;
    const n = try integer(&modulus, try codec.text(try codec.field(value, "n")));
    const e = try integer(&exponent, try codec.text(try codec.field(value, "e")));
    if ((n.len != 256 and n.len != 384 and n.len != 512) or n[0] & 0x80 == 0 or n[n.len - 1] & 1 == 0) return error.UnsupportedServiceKeySize;
    return .{ .key = Rsa.PublicKey.fromBytes(e, n) catch return error.InvalidServiceKey, .modulus_bytes = @intCast(n.len) };
}

fn integer(output: []u8, input: []const u8) ![]const u8 {
    if (input.len == 0 or input.len > std.base64.url_safe_no_pad.Encoder.calcSize(output.len) or std.mem.indexOfScalar(u8, input, '=') != null) return error.InvalidServiceKey;
    const bytes = codec.decode(output, input, true) catch return error.InvalidServiceKey;
    if (bytes.len == 0 or bytes[0] == 0) return error.InvalidServiceKey;
    return bytes;
}

/// No allocation or provider call. The original JWS signing input is verified,
/// with one exact signature length for the selected public modulus.
pub fn verify(self: *const PublicKey, input: []const u8, signature: []const u8) !void {
    if (input.len > 64 * 1024) return error.IdentityBytesLimit;
    if (signature.len != self.modulus_bytes) return error.InvalidServiceSignatureLength;
    inline for (.{ 256, 384, 512 }) |length| {
        if (self.modulus_bytes == length) {
            Rsa.PKCS1v1_5Signature.verify(length, signature[0..length], input, self.key, std.crypto.hash.sha2.Sha256) catch return error.ServiceSignatureMismatch;
            return;
        }
    }
    return error.UnsupportedServiceKeySize;
}
