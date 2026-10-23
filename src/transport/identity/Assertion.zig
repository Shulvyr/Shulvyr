const std = @import("std");
const codec = @import("codec.zig");
const PublicKey = @import("PublicKey.zig");
const Value = codec.Value;
const Assertion = @This();

pub const Limits = struct {
    attribute_bytes: usize = 16 * 1024,
    token_bytes: usize = 12 * 1024,
    json_bytes: usize = 16 * 1024,
    json_depth: usize = 8,
    json_tokens: usize = 512,
    decoded_bytes: usize = 32 * 1024,
    storage_bytes: usize = 128 * 1024,
    fingerprint_payload_bytes: usize = 16 * 1024,

    fn validate(self: Limits) !void {
        inline for (@typeInfo(Limits).@"struct".field_names) |name| if (@field(self, name) == 0) return error.InvalidLimits;
        if (self.attribute_bytes > 64 * 1024 or self.token_bytes > 64 * 1024 or self.json_bytes > 64 * 1024 or
            self.json_depth > 32 or self.json_tokens > 4096 or self.decoded_bytes > 256 * 1024 or
            self.storage_bytes > 1024 * 1024 or self.fingerprint_payload_bytes > 64 * 1024) return error.InvalidLimits;
    }
};

/// Borrowed views belong to the containing Assertion's single owned allocation.
/// A parsed token is untrusted. Neither parsing nor time checks verify issuance.
pub const Token = struct {
    compact: []const u8,
    signing_input: []const u8,
    signature: []const u8,
    header: Value,
    claims: Value,
    public_key: PublicKey,

    pub fn verifyEs384(self: *const Token, key: *const PublicKey) !void {
        try codec.es384Header(self.header);
        try key.verify(self.signing_input, self.signature);
    }

    pub fn checkTimestamps(self: Token, now: i64, leeway_seconds: u32) !void {
        const future = @as(i128, now) + leeway_seconds;
        if (try self.timestamp("nbf")) |value| if (future < value) return error.IdentityNotYetValid;
        if (try self.timestamp("iat")) |value| if (future < value) return error.IdentityIssuedInFuture;
        if (try self.timestamp("exp")) |value| if (@as(i128, now) - leeway_seconds >= value) return error.IdentityExpired;
    }

    fn timestamp(self: Token, name: []const u8) !?i64 {
        const value = self.claims.object.get(name) orelse return null;
        return switch (value) {
            .null => null,
            .integer => value.integer,
            .float => blk: {
                if (!std.math.isFinite(value.float) or value.float < -0x1p63 or value.float >= 0x1p63) return error.InvalidIdentityTimestamp;
                break :blk @intFromFloat(value.float);
            },
            else => error.InvalidIdentityTimestamp,
        };
    }
};

allocator: std.mem.Allocator,
storage: []u8,
domain: []const u8,
token: Token,
proof_header: []const u8,
proof_signature: [96]u8,
limits: Limits,

/// Retains strings and JSON in one bounded allocation. The public key and proof
/// signature are owned inline. Failure releases the allocation.
/// The returned owner may move, but must not be duplicated or freed twice.
pub fn parse(allocator: std.mem.Allocator, attribute: []const u8, limits: Limits) !Assertion {
    try limits.validate();
    if (attribute.len > limits.attribute_bytes) return error.IdentityBytesLimit;
    const storage = try allocator.alloc(u8, limits.storage_bytes);
    errdefer {
        std.crypto.secureZero(u8, storage);
        allocator.free(storage);
    }
    var fixed: std.heap.FixedBufferAllocator = .init(storage);
    var context: Context = .{ .allocator = fixed.allocator(), .limits = limits };
    return parseInner(allocator, storage, &context, attribute) catch |err| switch (err) {
        error.OutOfMemory => error.IdentityStorageLimit,
        else => err,
    };
}

pub fn deinit(self: *Assertion) void {
    std.crypto.secureZero(u8, self.storage);
    self.allocator.free(self.storage);
    self.* = undefined;
}

fn parseInner(allocator: std.mem.Allocator, storage: []u8, context: *Context, attribute: []const u8) !Assertion {
    const envelope = try context.object(try context.decode(attribute, false));
    const idp = try codec.field(envelope, "idp");
    const domain = try codec.text(try codec.field(idp, "domain"));
    if (domain.len == 0) return error.InvalidIdentityDomain;
    if (!std.mem.eql(u8, try codec.text(try codec.field(idp, "protocol")), "default")) return error.UnsupportedIdentityProtocol;
    const inner = try context.object(try codec.text(try codec.field(envelope, "assertion")));
    const compact = try codec.text(try codec.field(inner, "token"));
    if (compact.len > context.limits.token_bytes) return error.IdentityBytesLimit;
    const token_parts = try codec.segments(compact);
    const header = try context.object(try context.decode(token_parts[0], true));
    const claims = try context.object(try context.decode(token_parts[1], true));
    const key_claim = try codec.field(claims, "cpk");
    const signature = try context.decode(token_parts[2], true);
    const proof = try codec.segments(try codec.text(try codec.field(inner, "fingerprints")));
    if (proof[1].len != 0) return error.DetachedIdentityPayload;
    try codec.es384Header(try context.object(try context.decode(proof[0], true)));
    const proof_signature = try context.decode(proof[2], true);
    if (proof_signature.len != 96) return error.InvalidIdentitySignatureLength;
    // Complete structural and aggregate resource checks before curve decoding.
    const key = try context.publicKey(key_claim);
    return .{
        .allocator = allocator,
        .storage = storage,
        .domain = domain,
        .token = .{ .compact = compact, .signing_input = compact[0 .. token_parts[0].len + 1 + token_parts[1].len], .signature = signature, .header = header, .claims = claims, .public_key = key },
        .proof_header = proof[0],
        .proof_signature = proof_signature[0..96].*,
        .limits = context.limits,
    };
}

/// Verifies possession of cpk for the supplied canonical fingerprint payload.
/// It does not verify the JWT issuer, timestamps, claims or admission policy.
pub fn verifyFingerprint(self: *const Assertion, payload: []const u8) !void {
    if (payload.len > self.limits.fingerprint_payload_bytes) return error.IdentityBytesLimit;
    var verifier = try self.token.public_key.startVerifier(&self.proof_signature);
    verifier.update(self.proof_header);
    verifier.update(".");
    var buffer: [512]u8 = undefined;
    var rest = payload;
    while (rest.len != 0) {
        const count = @min(rest.len, 384);
        verifier.update(std.base64.url_safe_no_pad.Encoder.encode(&buffer, rest[0..count]));
        rest = rest[count..];
    }
    verifier.verify() catch return error.IdentitySignatureMismatch;
}

const Context = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    decoded: usize = 0,
    tokens: usize = 0,

    fn publicKey(self: *Context, claim: Value) !PublicKey {
        if (claim == .string) {
            if (claim.string.len > 256) return error.IdentityBytesLimit;
            var buffer: [120]u8 = undefined;
            const der = try codec.decode(&buffer, claim.string, false);
            if (der.len > self.limits.decoded_bytes - self.decoded) return error.IdentityBytesLimit;
            self.decoded += der.len;
            return PublicKey.fromDer(der);
        }
        if (96 > self.limits.decoded_bytes - self.decoded) return error.IdentityBytesLimit;
        self.decoded += 96;
        return PublicKey.fromClaim(claim);
    }

    fn decode(self: *Context, input: []const u8, url: bool) ![]const u8 {
        // Each encoded input already lives in an earlier bounded JSON document,
        // except the outer attribute, checked before allocating storage.
        const maximum = std.math.mul(usize, input.len / 4 + 1, 3) catch return error.IdentityBytesLimit;
        const remaining = self.limits.decoded_bytes - self.decoded;
        const buffer = try self.allocator.alloc(u8, @min(maximum, remaining));
        const result = try codec.decode(buffer, input, url);
        self.decoded += result.len;
        return result;
    }

    fn object(self: *Context, bytes: []const u8) !Value {
        if (bytes.len > self.limits.json_bytes) return error.IdentityBytesLimit;
        var scanner: std.json.Scanner = .initCompleteInput(self.allocator, bytes);
        defer scanner.deinit();
        var depth: usize = 0;
        while (true) {
            const next = try scanner.next();
            if (next == .end_of_document) break;
            if (self.tokens == self.limits.json_tokens) return error.IdentityTokensLimit;
            self.tokens += 1;
            switch (next) {
                .object_begin, .array_begin => {
                    if (depth == self.limits.json_depth) return error.IdentityDepthLimit;
                    depth += 1;
                },
                .object_end, .array_end => depth -= 1,
                else => {},
            }
        }
        const value = try std.json.parseFromSliceLeaky(Value, self.allocator, bytes, .{ .allocate = .alloc_if_needed, .duplicate_field_behavior = .@"error" });
        if (value != .object) return error.InvalidIdentityObject;
        return value;
    }
};
