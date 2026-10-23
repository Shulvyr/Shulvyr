const std = @import("std");
const buffer = @import("../buffer.zig");
const Fingerprint = @This();

algorithm: []const u8,
digest: []const u8,

/// Borrows value. The syntax reference accepts short hex digests and preserves
/// spelling. Use sha256Bytes for a concrete SHA-256 certificate digest.
pub fn parse(value: []const u8, maximum_bytes: usize) !Fingerprint {
    if (maximum_bytes == 0) return error.InvalidLimits;
    if (value.len > maximum_bytes) return error.FingerprintTooLong;
    const space = std.mem.indexOfScalar(u8, value, ' ') orelse return error.InvalidFingerprint;
    const result: Fingerprint = .{ .algorithm = value[0..space], .digest = value[space + 1 ..] };
    try result.validate();
    return result;
}

fn validate(self: Fingerprint) !void {
    if (!std.ascii.eqlIgnoreCase(self.algorithm, "sha-256")) return error.InvalidFingerprint;
    // PHP's reference regex permits a single final LF through its '$' anchor.
    // SDP line parsing removes line separators before extracting attributes.
    const hex = if (std.mem.endsWith(u8, self.digest, "\n")) self.digest[0 .. self.digest.len - 1] else self.digest;
    if (hex.len % 3 != 2) return error.InvalidFingerprint;
    for (hex, 0..) |byte, index| {
        if (index % 3 == 2) {
            if (byte != ':') return error.InvalidFingerprint;
        } else if (!std.ascii.isHex(byte)) return error.InvalidFingerprint;
    }
}

pub fn equals(self: Fingerprint, other: Fingerprint) bool {
    return std.ascii.eqlIgnoreCase(self.algorithm, other.algorithm) and std.ascii.eqlIgnoreCase(self.digest, other.digest);
}

pub fn sha256Bytes(self: Fingerprint) ![32]u8 {
    if (self.digest.len != 95) return error.InvalidDigestLength;
    try self.validate();
    var result: [32]u8 = undefined;
    for (&result, 0..) |*byte, index| {
        byte.* = (try std.fmt.charToDigit(self.digest[index * 3], 16)) * 16 + try std.fmt.charToDigit(self.digest[index * 3 + 1], 16);
    }
    return result;
}

/// Preflighted output borrows caller storage. Failure leaves output unchanged.
/// The reference signature payload preserves algorithm and digest spelling.
pub fn writeCanonical(self: *const Fingerprint, output: []u8, maximum_bytes: usize) ![]const u8 {
    return self.writeParts(output, maximum_bytes, true);
}

pub fn writeAttribute(self: *const Fingerprint, output: []u8, maximum_bytes: usize) ![]const u8 {
    return self.writeParts(output, maximum_bytes, false);
}

fn writeParts(self: *const Fingerprint, output: []u8, maximum_bytes: usize, canonical: bool) ![]const u8 {
    if (maximum_bytes == 0) return error.InvalidLimits;
    const parts: [5][]const u8 = if (canonical)
        .{ "{\"fingerprint\":[{\"algorithm\":\"", self.algorithm, "\",\"digest\":\"", self.digest, "\"}]}" }
    else
        .{ "", self.algorithm, " ", self.digest, "" };
    var needed: usize = 0;
    for (parts) |part| needed = std.math.add(usize, needed, part.len) catch return error.FingerprintTooLong;
    if (needed > maximum_bytes) return error.FingerprintTooLong;
    try self.validate();
    if (needed > output.len) return error.NoSpace;
    const destination = output[0..needed];
    if (buffer.overlaps(destination, std.mem.asBytes(self)) or buffer.overlaps(destination, self.algorithm) or buffer.overlaps(destination, self.digest)) return error.AliasedBuffer;
    var position: usize = 0;
    for (parts) |part| {
        @memcpy(destination[position..][0..part.len], part);
        position += part.len;
    }
    return destination;
}
