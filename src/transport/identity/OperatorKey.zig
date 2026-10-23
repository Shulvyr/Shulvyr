const std = @import("std");
const PublicKey = @import("PublicKey.zig");
const buffer = @import("../buffer.zig");
const OperatorKey = @This();
const Ecdsa = PublicKey.Ecdsa;

pair: Ecdsa.KeyPair,
public_key: PublicKey,
active: bool,

/// Owns a private scalar until deinit. Do not duplicate the owner. Serialize
/// signing, export and destruction in its owner context. This is not a key file.
pub fn generate(io: std.Io) !OperatorKey {
    var pair = Ecdsa.KeyPair.generate(io);
    defer std.crypto.secureZero(u8, &pair.secret_key.bytes);
    return .{ .pair = pair, .public_key = try PublicKey.fromSec1(&pair.public_key.toUncompressedSec1()), .active = true };
}

/// Copies a canonical, nonzero 48-byte big-endian scalar. The caller still owns
/// and must protect or clear its input. The import performs no filesystem I/O.
pub fn fromSecretScalar(secret: []const u8) !OperatorKey {
    if (secret.len != 48) return error.InvalidSecretScalar;
    var scalar = Ecdsa.Curve.scalar.Scalar.fromBytes(secret[0..48].*, .big) catch return error.InvalidSecretScalar;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&scalar));
    if (scalar.isZero()) return error.InvalidSecretScalar;
    var pair = try Ecdsa.KeyPair.fromSecretKey(.{ .bytes = secret[0..48].* });
    defer std.crypto.secureZero(u8, &pair.secret_key.bytes);
    return .{ .pair = pair, .public_key = try PublicKey.fromSec1(&pair.public_key.toUncompressedSec1()), .active = true };
}

/// Clears owned key material. Further operations fail with OperatorKeyDestroyed.
pub fn deinit(self: *OperatorKey) void {
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    self.active = false;
}

pub fn publicKey(self: *const OperatorKey) !PublicKey {
    if (!self.active) return error.OperatorKeyDestroyed;
    return self.public_key;
}

/// Explicit secret export for a caller-managed store. The returned bytes are
/// private key material. Output is unchanged on failure and cannot alias self.
pub fn writeSecretScalar(self: *const OperatorKey, output: []u8) ![]const u8 {
    if (!self.active) return error.OperatorKeyDestroyed;
    if (output.len < 48) return error.NoSpace;
    if (buffer.overlaps(output[0..48], std.mem.asBytes(self))) return error.AliasedBuffer;
    @memcpy(output[0..48], &self.pair.secret_key.bytes);
    return output[0..48];
}

/// Noise is supplied by the caller's CSPRNG. Null uses the pinned standard
/// library's deterministic signing mode. Signatures own their 96 public bytes.
pub fn sign(self: *const OperatorKey, input: []const u8, noise: ?[48]u8) ![96]u8 {
    if (!self.active) return error.OperatorKeyDestroyed;
    if (input.len > 64 * 1024) return error.IdentityBytesLimit;
    return (try self.pair.sign(input, noise)).toBytes();
}

/// Deliberate formatting uses a redacted representation. In-process callers
/// must still avoid structural dumps and keep raw private fields out of logs.
pub fn format(_: *const OperatorKey, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("OperatorKey(redacted)");
}
