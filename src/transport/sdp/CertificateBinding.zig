const std = @import("std");
const Description = @import("SessionDescription.zig");
const Fingerprint = @import("Fingerprint.zig");

/// One DTLS certificate backs this provider's bundled data channels. Every
/// session/media fingerprint must name that exact full-certificate SHA-256.
/// Validation allocates nothing and changes no caller storage.
pub fn validate(description: *const Description, expected: [32]u8) !void {
    try description.validate();
    var values = description.attributes("fingerprint", .all);
    var count: usize = 0;
    while (values.next()) |value| {
        const parsed = try Fingerprint.parse(value, description.limits.line_bytes);
        const actual = try parsed.sha256Bytes();
        if (!std.mem.eql(u8, &actual, &expected)) return error.CertificateFingerprintMismatch;
        count += 1;
    }
    if (count == 0) return error.MissingFingerprint;
}
