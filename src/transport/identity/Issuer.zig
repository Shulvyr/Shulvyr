const std = @import("std");
const OperatorKey = @import("OperatorKey.zig");
const PublicKey = @import("PublicKey.zig");
const buffer = @import("../buffer.zig");
const Writer = std.Io.Writer;
const url = std.base64.url_safe_no_pad.Encoder;
const standard = std.base64.standard.Encoder;
const proof_header = "eyJhbGciOiJFUzM4NCJ9";
const signature_text_bytes = 128;

pub const Encoding = enum { jwk, legacy_der };
pub const Parameters = struct {
    now: i64,
    lifetime_seconds: u32 = 60,
    domain: []const u8 = "self",
    key_encoding: Encoding = .jwk,
};
pub const Limits = struct {
    attribute_bytes: usize = 16 * 1024,
    domain_bytes: usize = 256,
    payload_bytes: usize = 16 * 1024,
};

/// Writes an owned-key assertion into caller output, using io's CSPRNG for
/// signing noise. The key is borrowed only for this synchronous call. Generate
/// or load it once per operator lifetime, rather than once per connection.
pub fn write(key: *const OperatorKey, io: std.Io, output: []u8, workspace: []u8, payload: []const u8, parameters: Parameters, limits: Limits) ![]const u8 {
    if (buffer.overlaps(output, std.mem.asBytes(key)) or buffer.overlaps(workspace, std.mem.asBytes(key))) return error.AliasedBuffer;
    const public = try key.publicKey();
    var signer: KeySigner = .{ .key = key, .io = io };
    return writeSigned(&signer, &public, output, workspace, payload, parameters, limits);
}

const KeySigner = struct {
    key: *const OperatorKey,
    io: std.Io,

    pub fn sign(self: *KeySigner, input: []const u8) ![96]u8 {
        var noise: [48]u8 = undefined;
        self.io.random(&noise);
        defer std.crypto.secureZero(u8, &noise);
        return self.key.sign(input, noise);
    }
};

/// Synchronous key-provider boundary. signer.sign(input) returns a raw ES384
/// signature for public. It must not retain or modify input or caller buffers.
/// Both signatures are verified before publication. Every failure preserves
/// output, while workspace may change. No signer call occurs before preflight.
pub fn writeSigned(signer: anytype, public: *const PublicKey, output: []u8, workspace: []u8, payload: []const u8, parameters: Parameters, limits: Limits) ![]const u8 {
    const protected = [_][]const u8{ std.mem.asBytes(public), std.mem.asBytes(signer), payload, parameters.domain };
    if (buffer.overlaps(output, workspace)) return error.AliasedBuffer;
    for (protected) |bytes| if (buffer.overlaps(output, bytes) or buffer.overlaps(workspace, bytes)) return error.AliasedBuffer;
    if (limits.attribute_bytes == 0 or limits.domain_bytes == 0 or limits.payload_bytes == 0 or
        limits.attribute_bytes > 64 * 1024 or limits.domain_bytes > 1024 or limits.payload_bytes > 16 * 1024) return error.InvalidLimits;
    if (parameters.domain.len == 0 or parameters.domain.len > limits.domain_bytes or !std.unicode.utf8ValidateSlice(parameters.domain)) return error.InvalidIdentityDomain;
    if (parameters.lifetime_seconds == 0) return error.InvalidIdentityLifetime;
    if (payload.len > limits.payload_bytes) return error.IdentityBytesLimit;
    const expiry = std.math.add(i64, parameters.now, parameters.lifetime_seconds) catch return error.InvalidIdentityTimestamp;
    var fixed: std.heap.FixedBufferAllocator = .init(workspace);
    const allocator = fixed.allocator();
    const point = public.key.toUncompressedSec1();
    var der_encoded: [160]u8 = undefined;
    var x_encoded: [64]u8 = undefined;
    var y_encoded: [64]u8 = undefined;
    // Normalize key presentation for stable operator identity. A compressed
    // provider key still emits canonical uncompressed SPKI/JWK coordinates.
    const canonical_key = try PublicKey.fromSec1(&point);
    const parts: KeyParts = .{
        .der = standard.encode(&der_encoded, canonical_key.derBytes()),
        .x = url.encode(&x_encoded, point[1..49]),
        .y = url.encode(&y_encoded, point[49..97]),
    };
    const header = try build(allocator, writeHeader, .{parts});
    const claims = try build(allocator, writeClaims, .{ parts, parameters, expiry });
    const token_unsigned_length = url.calcSize(header.len) + 1 + url.calcSize(claims.len);
    const token = try alloc(allocator, token_unsigned_length + 1 + signature_text_bytes);
    const header_length = url.calcSize(header.len);
    _ = url.encode(token[0..header_length], header);
    token[header_length] = '.';
    _ = url.encode(token[header_length + 1 .. token_unsigned_length], claims);
    token[token_unsigned_length] = '.';
    @memset(token[token_unsigned_length + 1 ..], 'A');
    const proof_unsigned = try alloc(allocator, proof_header.len + 1 + url.calcSize(payload.len));
    @memcpy(proof_unsigned[0..proof_header.len], proof_header);
    proof_unsigned[proof_header.len] = '.';
    _ = url.encode(proof_unsigned[proof_header.len + 1 ..], payload);
    const proof = try alloc(allocator, proof_header.len + 2 + signature_text_bytes);
    @memcpy(proof[0..proof_header.len], proof_header);
    @memcpy(proof[proof_header.len..][0..2], "..");
    @memset(proof[proof_header.len + 2 ..], 'A');
    const inner = try build(allocator, writeInner, .{ token, proof });
    const outer = try build(allocator, writeOuter, .{ inner, parameters.domain });
    const required = standard.calcSize(outer.len);
    if (required > limits.attribute_bytes) return error.IdentityBytesLimit;
    if (required > output.len) return error.NoSpace;

    const token_signature = try signer.sign(token[0..token_unsigned_length]);
    try canonical_key.verify(token[0..token_unsigned_length], &token_signature);
    const proof_signature = try signer.sign(proof_unsigned);
    try canonical_key.verify(proof_unsigned, &proof_signature);
    _ = url.encode(token[token_unsigned_length + 1 ..], &token_signature);
    _ = url.encode(proof[proof_header.len + 2 ..], &proof_signature);
    try rewrite(inner, writeInner, .{ token, proof });
    try rewrite(outer, writeOuter, .{ inner, parameters.domain });
    return standard.encode(output[0..required], outer);
}

const KeyParts = struct { der: []const u8, x: []const u8, y: []const u8 };

fn alloc(allocator: std.mem.Allocator, length: usize) ![]u8 {
    return allocator.alloc(u8, length) catch return error.IdentityWorkspaceLimit;
}

fn build(allocator: std.mem.Allocator, comptime emit: anytype, arguments: anytype) ![]u8 {
    var counting_buffer: [128]u8 = undefined;
    var count: Writer.Discarding = .init(&counting_buffer);
    try @call(.auto, emit, .{&count.writer} ++ arguments);
    const length = std.math.cast(usize, count.fullCount()) orelse return error.IdentityBytesLimit;
    const result = try alloc(allocator, length);
    try rewrite(result, emit, arguments);
    return result;
}

fn rewrite(output: []u8, comptime emit: anytype, arguments: anytype) !void {
    var writer: Writer = .fixed(output);
    try @call(.auto, emit, .{&writer} ++ arguments);
    if (writer.end != output.len) return error.InvalidIdentityEncodingLength;
}

fn writeHeader(writer: *Writer, parts: KeyParts) !void {
    try std.json.Stringify.value(.{ .x5u = parts.der, .alg = "ES384" }, .{ .escape_unicode = true }, writer);
}

fn writeClaims(writer: *Writer, parts: KeyParts, parameters: Parameters, expiry: i64) !void {
    try writer.print("{{\"exp\":{d},\"iat\":{d},\"cpk\":", .{ expiry, parameters.now });
    switch (parameters.key_encoding) {
        .legacy_der => try std.json.Stringify.value(parts.der, .{}, writer),
        .jwk => try std.json.Stringify.value(.{ .kty = "EC", .crv = "P-384", .x = parts.x, .y = parts.y }, .{}, writer),
    }
    try writer.writeByte('}');
}

fn writeInner(writer: *Writer, token: []const u8, proof: []const u8) !void {
    try std.json.Stringify.value(.{ .fingerprints = proof, .token = token }, .{ .escape_unicode = true }, writer);
}

fn writeOuter(writer: *Writer, inner: []const u8, domain: []const u8) !void {
    try std.json.Stringify.value(.{ .assertion = inner, .idp = .{ .domain = domain, .protocol = "default" } }, .{ .escape_unicode = true }, writer);
}
