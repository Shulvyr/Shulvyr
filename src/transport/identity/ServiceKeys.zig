const std = @import("std");
const codec = @import("codec.zig");
const RsaKey = @import("RsaPublicKey.zig");
const Keys = @This();

pub const max_keys = 16;
pub const Authority = struct {
    issuer: []const u8,
    audience: []const u8,
    not_before: i64,
    expires_at: i64,
    generation: u64,
};
pub const Limits = struct { json_bytes: usize = 32 * 1024, keys: usize = 8, storage_bytes: usize = 128 * 1024, json_depth: usize = 8, json_tokens: usize = 2048 };
const Entry = struct { id: []const u8, key: RsaKey };

allocator: std.mem.Allocator,
storage: []u8,
authority: Authority,
entries: [max_keys]Entry,
count: usize,
active: bool = true,

/// Owns a bounded immutable snapshot supplied by a trusted management path.
/// Parsing JWKS does not authenticate its source. No network request is made.
/// Authority strings and key IDs are copied, so input may be released after
/// success. The owner may move, but must not be duplicated or used concurrently
/// with destruction. Borrow it until all synchronous verifications return.
pub fn load(allocator: std.mem.Allocator, input: []const u8, authority: Authority, limits: Limits) !Keys {
    if (limits.json_bytes == 0 or limits.json_bytes > 64 * 1024 or limits.keys == 0 or limits.keys > max_keys or
        limits.storage_bytes == 0 or limits.storage_bytes > 256 * 1024 or limits.json_depth == 0 or limits.json_depth > 16 or limits.json_tokens == 0 or limits.json_tokens > 4096) return error.InvalidLimits;
    if (input.len > limits.json_bytes) return error.JwksBytesLimit;
    try validText(authority.issuer, 512);
    try validText(authority.audience, 512);
    if (authority.not_before < 0 or authority.expires_at <= authority.not_before or @as(i128, authority.expires_at) - authority.not_before > 86400 or authority.generation == 0) return error.InvalidServiceAuthority;
    const storage = try allocator.alloc(u8, limits.storage_bytes);
    errdefer allocator.free(storage);
    var fixed: std.heap.FixedBufferAllocator = .init(storage);
    return loadInner(allocator, storage, fixed.allocator(), input, authority, limits) catch |err| switch (err) {
        error.OutOfMemory => error.JwksStorageLimit,
        else => err,
    };
}

fn loadInner(allocator: std.mem.Allocator, storage: []u8, scratch: std.mem.Allocator, input: []const u8, authority: Authority, limits: Limits) !Keys {
    var scanner: std.json.Scanner = .initCompleteInput(scratch, input);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) break;
        if (tokens == limits.json_tokens) return error.JwksTokensLimit;
        tokens += 1;
        switch (token) {
            .object_begin, .array_begin => {
                if (depth == limits.json_depth) return error.JwksDepthLimit;
                depth += 1;
            },
            .object_end, .array_end => depth -= 1,
            else => {},
        }
    }
    const root = try std.json.parseFromSliceLeaky(codec.Value, scratch, input, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    const keys = try codec.field(root, "keys");
    if (keys != .array or keys.array.items.len == 0) return error.InvalidJwks;
    if (keys.array.items.len > limits.keys) return error.JwksKeysLimit;
    var result: Keys = .{ .allocator = allocator, .storage = storage, .authority = authority, .entries = undefined, .count = 0 };
    result.authority.issuer = try scratch.dupe(u8, authority.issuer);
    result.authority.audience = try scratch.dupe(u8, authority.audience);
    for (keys.array.items) |value| {
        const id = try codec.text(try codec.field(value, "kid"));
        try validText(id, 128);
        for (result.entries[0..result.count]) |entry| if (std.mem.eql(u8, id, entry.id)) return error.DuplicateServiceKey;
        result.entries[result.count] = .{ .id = id, .key = try RsaKey.fromJwk(value) };
        result.count += 1;
    }
    return result;
}

pub fn deinit(self: *Keys) void {
    if (!self.active) return;
    const allocator = self.allocator;
    const storage = self.storage;
    std.crypto.secureZero(u8, storage);
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    allocator.free(storage);
}

pub fn checkTime(self: *const Keys, now: i64) !void {
    if (!self.active) return error.ServiceKeysDestroyed;
    if (now < self.authority.not_before) return error.ServiceKeysNotYetValid;
    if (now >= self.authority.expires_at) return error.ServiceKeysExpired;
}

pub fn verify(self: *const Keys, id: []const u8, input: []const u8, signature: []const u8, now: i64) !void {
    try self.checkTime(now);
    try validText(id, 128);
    for (self.entries[0..self.count]) |*entry| {
        if (std.mem.eql(u8, id, entry.id)) return entry.key.verify(input, signature);
    }
    return error.UnknownServiceKey;
}

pub fn validText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) return error.InvalidServiceIdentifier;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidServiceIdentifier;
}

pub fn format(_: *const Keys, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("ServiceKeys");
}
