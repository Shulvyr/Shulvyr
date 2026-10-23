const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Frozen source metadata from the separate reference-tools repository.
/// Normal fixture checks need only this local snapshot. verifyCheckout hashes
/// an explicitly supplied reference checkout without executing its sources.
pub const Snapshot = struct {
    files: Value,
    revision: []const u8,

    pub fn load(allocator: Allocator, io: std.Io) !Snapshot {
        const pin = try parse(allocator, try read(allocator, io, "data/reference-tools/source.json"));
        if (pin != .object or pin.object.count() != 4 or (try field(pin, "schema")) != .integer or (try field(pin, "schema")).integer != 1) return error.InvalidReferenceSource;
        if (!std.mem.eql(u8, try text(try field(pin, "repository")), "https://github.com/Shulvyr/reference-tools")) return error.InvalidReferenceSource;
        const revision = try text(try field(pin, "revision"));
        try hex(revision, 40);
        const bytes = try read(allocator, io, "data/reference-tools/manifest.json");
        try digest(bytes, try text(try field(pin, "manifest_sha256")));
        const manifest = try parse(allocator, bytes);
        const schema = try field(manifest, "schema");
        if (manifest != .object or manifest.object.count() != 2 or schema != .integer or schema.integer != 1) return error.InvalidReferenceSource;
        const files = try field(manifest, "files");
        if (files != .object or files.object.count() == 0 or files.object.count() > 64) return error.InvalidReferenceSource;
        var entries = files.object.iterator();
        while (entries.next()) |entry| {
            try sourcePath(entry.key_ptr.*);
            const value = entry.value_ptr.*;
            const size = try field(value, "bytes");
            if (value != .object or value.object.count() != 2 or size != .integer or size.integer < 0 or size.integer > 1024 * 1024) return error.InvalidReferenceSource;
            try hex(try text(try field(value, "sha256")), 64);
        }
        return .{ .files = files, .revision = revision };
    }

    pub fn expect(self: Snapshot, path: []const u8, sha256: []const u8) !void {
        try sourcePath(path);
        try hex(sha256, 64);
        const expected = try field(self.files, path);
        if (!std.mem.eql(u8, sha256, try text(try field(expected, "sha256")))) return error.ReferenceSourceMismatch;
    }

    pub fn verifyCheckout(self: Snapshot, allocator: Allocator, io: std.Io, root: []const u8) !usize {
        var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
        defer directory.close(io);
        var entries = self.files.object.iterator();
        while (entries.next()) |entry| {
            const bytes = try directory.readFileAlloc(io, entry.key_ptr.*, allocator, .limited(1024 * 1024));
            const metadata = entry.value_ptr.*;
            const wanted: usize = @intCast((try field(metadata, "bytes")).integer);
            if (bytes.len != wanted) return error.ReferenceSourceMismatch;
            try digest(bytes, try text(try field(metadata, "sha256")));
        }
        return self.files.object.count();
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3 or !std.mem.eql(u8, arguments[1], "--root")) return error.ExpectedReferenceCheckout;
    const snapshot = try Snapshot.load(init.arena.allocator(), init.io);
    const count = try snapshot.verifyCheckout(init.arena.allocator(), init.io, arguments[2]);
    var bytes: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &bytes);
    try output.interface.print("Verified {d} reference source hashes against snapshot {s}\n", .{ count, snapshot.revision });
    try output.interface.flush();
    return 0;
}

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidReferenceSource;
    return value.object.get(name) orelse error.InvalidReferenceSource;
}
fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidReferenceSource;
    return value.string;
}
pub fn parse(allocator: Allocator, bytes: []const u8) !Value {
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '[', '{' => {
                if (depth == 32) return error.JsonDepthLimit;
                depth += 1;
            },
            ']', '}' => {
                if (depth == 0) return error.InvalidJsonStructure;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or escaped or depth != 0) return error.InvalidJsonStructure;
    return std.json.parseFromSliceLeaky(Value, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always });
}
fn read(allocator: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
}
fn hex(value: []const u8, length: usize) !void {
    if (value.len != length) return error.InvalidReferenceSource;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidReferenceSource;
}
fn digest(bytes: []const u8, expected: []const u8) !void {
    try hex(expected, 64);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(actual, .lower), expected)) return error.ReferenceSourceMismatch;
}
fn sourcePath(path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "tools/")) return error.InvalidReferenceSource;
    for (path) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_/.-", byte) == null) return error.InvalidReferenceSource;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidReferenceSource;
}

test "reference provenance rejects hash drift, unsafe paths and noncanonical revisions" {
    try digest("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectError(error.ReferenceSourceMismatch, digest("abd", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    for ([_][]const u8{ "../private", "tools/../private", "tools//file", "tools/./file", "tools/file\n", "C:/private" }) |path| try std.testing.expectError(error.InvalidReferenceSource, sourcePath(path));
    try std.testing.expectError(error.InvalidReferenceSource, hex("main", 40));
    try std.testing.expectError(error.InvalidReferenceSource, hex("ABCDEF0123456789abcdef0123456789abcdef0123", 40));
}

test "maintenance JSON preflights depth and rejects duplicate fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var nested: [67]u8 = undefined;
    @memset(nested[0..33], '[');
    nested[33] = '0';
    @memset(nested[34..], ']');
    try std.testing.expectError(error.JsonDepthLimit, parse(allocator, &nested));
    try std.testing.expectError(error.InvalidJsonStructure, parse(allocator, "[0"));
    try std.testing.expectError(error.DuplicateField, parse(allocator, "{\"a\":1,\"a\":2}"));
}
