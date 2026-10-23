const std = @import("std");
const Description = @import("SessionDescription.zig");
const Fingerprint = @import("Fingerprint.zig");
const buffer = @import("../buffer.zig");
const prefix = "{\"fingerprint\":[";
const suffix = "]}";

pub const Limits = struct { bytes: usize = 16 * 1024, fingerprints: usize = 16 };

/// Target-protocol payload covering every fingerprint attribute in wire order.
/// Requires concrete SHA-256 digests, unlike the source-behavior syntax helper.
/// Borrows the description. Failure leaves output unchanged and allocates nothing.
pub fn write(description: *const Description, output: []u8, limits: Limits) ![]const u8 {
    if (limits.bytes == 0 or limits.fingerprints == 0 or limits.fingerprints > Description.max_lines) return error.InvalidLimits;
    var values = description.attributes("fingerprint", .all);
    var count: usize = 0;
    var needed: usize = prefix.len + suffix.len;
    while (values.next()) |value| {
        if (count == limits.fingerprints) return error.TooManyFingerprints;
        const fingerprint = try Fingerprint.parse(value, description.limits.line_bytes);
        _ = try fingerprint.sha256Bytes();
        for (parts(fingerprint)) |part| needed = std.math.add(usize, needed, part.len) catch return error.FingerprintPayloadTooLong;
        if (count != 0) needed = std.math.add(usize, needed, 1) catch return error.FingerprintPayloadTooLong;
        count += 1;
    }
    if (count == 0) return error.MissingFingerprint;
    if (needed > limits.bytes) return error.FingerprintPayloadTooLong;
    if (needed > output.len) return error.NoSpace;
    const destination = output[0..needed];
    if (buffer.overlaps(destination, std.mem.asBytes(description)) or buffer.overlaps(destination, description.source) or
        buffer.overlaps(destination, std.mem.sliceAsBytes(description.lines))) return error.AliasedBuffer;
    for (description.lines) |line| if (buffer.overlaps(destination, line)) return error.AliasedBuffer;
    var position: usize = 0;
    append(destination, &position, prefix);
    values = description.attributes("fingerprint", .all);
    var index: usize = 0;
    while (values.next()) |value| : (index += 1) {
        if (index != 0) append(destination, &position, ",");
        const fingerprint = try Fingerprint.parse(value, description.limits.line_bytes);
        for (parts(fingerprint)) |part| append(destination, &position, part);
    }
    append(destination, &position, suffix);
    return destination;
}

fn parts(fingerprint: Fingerprint) [5][]const u8 {
    return .{ "{\"algorithm\":\"", fingerprint.algorithm, "\",\"digest\":\"", fingerprint.digest, "\"}" };
}

fn append(output: []u8, position: *usize, bytes: []const u8) void {
    @memcpy(output[position.*..][0..bytes.len], bytes);
    position.* += bytes.len;
}
