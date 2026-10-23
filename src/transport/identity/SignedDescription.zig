const std = @import("std");
const Description = @import("../sdp/SessionDescription.zig");
const Fingerprints = @import("../sdp/FingerprintPayload.zig");
const OperatorKey = @import("OperatorKey.zig");
const Issuer = @import("Issuer.zig");
const buffer = @import("../buffer.zig");

pub const Limits = struct {
    description: Description.Limits = .{},
    fingerprints: Fingerprints.Limits = .{},
    identity: Issuer.Limits = .{},
};

/// Binds an operator assertion to all fingerprints in a borrowed local SDP.
/// Removes existing identity attributes in every scope and inserts one session
/// identity. This does not create an SDP answer or validate ICE/DTLS negotiation.
/// All buffers are caller-owned. Failure preserves output, but may change
/// workspace and may occur after signing. No borrowed input is retained.
pub fn write(key: *const OperatorKey, io: std.Io, description: *const Description, output: []u8, workspace: []u8, parameters: Issuer.Parameters, limits: Limits) ![]const u8 {
    const protected = [_][]const u8{
        std.mem.asBytes(key),                    std.mem.asBytes(description), description.source,
        std.mem.sliceAsBytes(description.lines), parameters.domain,
    };
    if (buffer.overlaps(output, workspace)) return error.AliasedBuffer;
    for (protected) |bytes| if (buffer.overlaps(output, bytes) or buffer.overlaps(workspace, bytes)) return error.AliasedBuffer;
    for (description.lines) |line| if (buffer.overlaps(output, line) or buffer.overlaps(workspace, line)) return error.AliasedBuffer;
    if (limits.description.text_bytes == 0 or limits.description.text_bytes > 64 * 1024 or
        limits.fingerprints.bytes == 0 or limits.fingerprints.bytes > 16 * 1024 or
        limits.identity.attribute_bytes == 0 or limits.identity.attribute_bytes > 64 * 1024) return error.InvalidLimits;
    _ = try key.publicKey();
    var fixed: std.heap.FixedBufferAllocator = .init(workspace);
    const allocator = fixed.allocator();
    const staging = allocator.alloc(u8, limits.description.text_bytes) catch return error.IdentityWorkspaceLimit;
    const payload_buffer = allocator.alloc(u8, limits.fingerprints.bytes) catch return error.IdentityWorkspaceLimit;
    const identity_buffer = allocator.alloc(u8, limits.identity.attribute_bytes) catch return error.IdentityWorkspaceLimit;
    // Validate the normalized local input before either signature is computed.
    _ = try description.write(staging, .none, limits.description);
    const payload = try Fingerprints.write(description, payload_buffer, limits.fingerprints);
    const attribute = try Issuer.write(key, io, identity_buffer, workspace[fixed.end_index..], payload, parameters, limits.identity);
    const result = try description.write(staging, .{ .identity = attribute }, limits.description);
    if (result.len > output.len) return error.NoSpace;
    @memcpy(output[0..result.len], result);
    return output[0..result.len];
}
