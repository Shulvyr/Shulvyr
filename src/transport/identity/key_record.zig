const std = @import("std");
const Key = @import("OperatorKey.zig");
const PublicKey = @import("PublicKey.zig");
const buffer = @import("../buffer.zig");

pub const header = "SVYRKEY\x00" ++ "\x01\x00\x00\x00" ++ "\xa0\x00\x00\x00";
pub const record_bytes = 128;
pub const frame_bytes = 160;
const commit_domain = "Shulvyr operator key commit v1\x00";

/// Output contains a secret scalar and must be cleared by its owner. The digest
/// detects corruption, it is not authentication against a writable-store owner.
pub fn encode(key: *const Key, generation: u64, output: *[frame_bytes]u8) ![32]u8 {
    if (buffer.overlaps(output, std.mem.asBytes(key))) return error.AliasedBuffer;
    if (generation == 0) return error.InvalidKeyGeneration;
    const public = try key.publicKey();
    @memset(output, 0);
    std.mem.writeInt(u64, output[0..8], generation, .little);
    _ = try key.writeSecretScalar(output[8..56]);
    const fingerprint = public.digest();
    @memcpy(output[56..88], &fingerprint);
    const checksum = recordHash(output[0..96]);
    @memcpy(output[96..128], &checksum);
    const commit = commitHash(output[0..128]);
    @memcpy(output[128..160], &commit);
    return fingerprint;
}

pub fn validate(frame: *const [frame_bytes]u8, generation: u64) !void {
    if (std.mem.readInt(u64, frame[0..8], .little) != generation or !std.mem.allEqual(u8, frame[88..96], 0)) return error.CorruptKeyStore;
    const checksum = recordHash(frame[0..96]);
    const commit = commitHash(frame[0..128]);
    if (!std.mem.eql(u8, &checksum, frame[96..128]) or !std.mem.eql(u8, &commit, frame[128..160])) return error.CorruptKeyStore;
    var scalar = PublicKey.Ecdsa.Curve.scalar.Scalar.fromBytes(frame[8..56].*, .big) catch return error.CorruptKeyStore;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&scalar));
    if (scalar.isZero()) return error.CorruptKeyStore;
}

fn recordHash(bytes: []const u8) [32]u8 {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update(header);
    hash.update(bytes);
    return hash.finalResult();
}
fn commitHash(bytes: []const u8) [32]u8 {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update(commit_domain);
    hash.update(bytes);
    return hash.finalResult();
}
