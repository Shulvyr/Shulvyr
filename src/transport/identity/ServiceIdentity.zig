const std = @import("std");
const Assertion = @import("Assertion.zig");
const Keys = @import("ServiceKeys.zig");
const PublicKey = @import("PublicKey.zig");
const codec = @import("codec.zig");
const Description = @import("../sdp/SessionDescription.zig");
const Fingerprints = @import("../sdp/FingerprintPayload.zig");
const buffer = @import("../buffer.zig");

pub const Policy = struct { leeway_seconds: u32 = 30, fingerprints: Fingerprints.Limits = .{} };
/// An owned verification result. It retains no token, assertion, SDP or key-set
/// views. It does not authorize game permissions or bind a later game login.
pub const Verified = struct {
    subject_bytes: [256]u8,
    subject_length: u16,
    client_key: PublicKey,
    expires_at: i64,
    key_generation: u64,

    pub fn subject(self: *const Verified) []const u8 {
        return self.subject_bytes[0..self.subject_length];
    }
    pub fn format(_: *const Verified, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("VerifiedServiceIdentity(redacted)");
    }
};

/// Verifies RS256 with a caller-authenticated key snapshot, exact issuer and
/// audience, expiry/optional time claims, subject and the detached ES384 proof
/// over every SDP fingerprint. No token-controlled URL or embedded signing key
/// is consulted. All inputs remain immutable and borrowed for this synchronous
/// call. Workspace may change and must not overlap any borrowed owner.
pub fn verify(assertion: *const Assertion, description: *const Description, keys: *const Keys, now: i64, workspace: []u8, policy: Policy) !Verified {
    if (policy.leeway_seconds > 300 or policy.fingerprints.bytes == 0 or policy.fingerprints.bytes > 16 * 1024 or policy.fingerprints.fingerprints == 0 or policy.fingerprints.fingerprints > 16) return error.InvalidLimits;
    const protected = [_][]const u8{ std.mem.asBytes(assertion), assertion.storage, std.mem.asBytes(description), description.source, std.mem.sliceAsBytes(description.lines), std.mem.asBytes(keys), keys.storage };
    for (protected) |bytes| if (buffer.overlaps(workspace, bytes)) return error.AliasedBuffer;
    for (description.lines) |line| if (buffer.overlaps(workspace, line)) return error.AliasedBuffer;
    try keys.checkTime(now);
    const token = &assertion.token;
    const header = token.header;
    if (!std.mem.eql(u8, try codec.text(try codec.field(header, "alg")), "RS256")) return error.UnsupportedServiceAlgorithm;
    if (header.object.contains("crit") or header.object.contains("b64")) return error.UnsupportedServiceHeader;
    const kid = try codec.text(try codec.field(header, "kid"));
    const parts = try codec.segments(token.compact);
    for (parts) |part| {
        if (part.len == 0 or std.mem.indexOfScalar(u8, part, '=') != null) return error.InvalidCompactSignature;
    }
    try keys.verify(kid, token.signing_input, token.signature, now);
    const claims = token.claims;
    if (!std.mem.eql(u8, try codec.text(try codec.field(claims, "iss")), keys.authority.issuer)) return error.ServiceIssuerMismatch;
    const aud = try codec.field(claims, "aud");
    try audience(aud, keys.authority.audience);
    const expires_at = try timestamp(try codec.field(claims, "exp"));
    const leeway: i128 = policy.leeway_seconds;
    if (@as(i128, now) - leeway >= expires_at) return error.IdentityExpired;
    if (claims.object.get("nbf")) |value| {
        const not_before = try timestamp(value);
        if (not_before >= expires_at) return error.InvalidServiceTimestamp;
        if (@as(i128, now) + leeway < not_before) return error.IdentityNotYetValid;
    }
    if (claims.object.get("iat")) |value| {
        const issued_at = try timestamp(value);
        if (issued_at >= expires_at) return error.InvalidServiceTimestamp;
        if (@as(i128, now) + leeway < issued_at) return error.IdentityIssuedInFuture;
    }
    const subject = try codec.text(try codec.field(claims, "sub"));
    try Keys.validText(subject, 256);
    const payload = try Fingerprints.write(description, workspace, policy.fingerprints);
    try assertion.verifyFingerprint(payload);
    var result: Verified = .{ .subject_bytes = @splat(0), .subject_length = @intCast(subject.len), .client_key = token.public_key, .expires_at = expires_at, .key_generation = keys.authority.generation };
    @memcpy(result.subject_bytes[0..subject.len], subject);
    return result;
}

fn timestamp(value: codec.Value) !i64 {
    if (value != .integer or value.integer < 0) return error.InvalidServiceTimestamp;
    return value.integer;
}

fn audience(value: codec.Value, expected: []const u8) !void {
    if (value == .string) {
        if (!std.mem.eql(u8, value.string, expected)) return error.ServiceAudienceMismatch;
    } else if (value == .array) {
        if (value.array.items.len == 0 or value.array.items.len > 16) return error.InvalidServiceAudience;
        var matched = false;
        for (value.array.items) |item| {
            const text = try codec.text(item);
            try Keys.validText(text, 512);
            matched = matched or std.mem.eql(u8, text, expected);
        }
        if (!matched) return error.ServiceAudienceMismatch;
    } else return error.InvalidServiceAudience;
}
