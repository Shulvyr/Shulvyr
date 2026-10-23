const std = @import("std");
const Json = @import("../reference_sources.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Dependency = struct { path: []const u8, repository: []const u8, license: []const u8 };
pub const channel_dependencies = [_]Dependency{
    .{ .path = "deps/plog", .repository = "https://github.com/SergiusTheBest/plog.git", .license = "MIT" },
    .{ .path = "deps/usrsctp", .repository = "https://github.com/paullouisageneau/usrsctp.git", .license = "BSD-3-Clause" },
    .{ .path = "deps/libjuice", .repository = "https://github.com/paullouisageneau/libjuice.git", .license = "MPL-2.0" },
};
pub const tls_dependencies = [_]Dependency{
    .{ .path = "framework", .repository = "https://github.com/Mbed-TLS/mbedtls-framework", .license = "Apache-2.0 OR GPL-2.0-or-later" },
};

pub const Manifest = struct {
    channel: Value,
    tls: Value,
    sha256: [64]u8,

    pub fn parse(allocator: Allocator, bytes: []const u8) !Manifest {
        if (bytes.len > 64 * 1024) return error.InvalidNativeManifest;
        const root = try Json.parse(allocator, bytes);
        try object(root, 2);
        const channel = try field(root, "libdatachannel");
        const tls = try field(root, "mbedtls");
        try source(channel, "https://github.com/paullouisageneau/libdatachannel.git", "MPL-2.0", &channel_dependencies, true);
        try source(tls, "https://github.com/Mbed-TLS/mbedtls.git", "Apache-2.0 OR GPL-2.0-or-later", &tls_dependencies, false);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return .{ .channel = channel, .tls = tls, .sha256 = std.fmt.bytesToHex(hash, .lower) };
    }
};

fn source(value: Value, repository: []const u8, license: []const u8, dependencies: []const Dependency, header: bool) !void {
    try object(value, if (header) 7 else 6);
    try equal(try string(value, "repository"), repository);
    try equal(try string(value, "license"), license);
    try hex(try string(value, "revision"), 40);
    for ([_][]const u8{ "branch", "version" }) |name| {
        const text = try string(value, name);
        if (text.len == 0 or text.len > 64) return error.InvalidNativeManifest;
        for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_.-", byte) == null) return error.InvalidNativeManifest;
    }
    if (header) try hex(try string(value, "header_lf_sha256"), 64);
    const children = try field(value, "submodules");
    try object(children, dependencies.len);
    for (dependencies) |dependency| {
        const child = try field(children, dependency.path);
        try object(child, 3);
        try equal(try string(child, "repository"), dependency.repository);
        try equal(try string(child, "license"), dependency.license);
        try hex(try string(child, "revision"), 40);
    }
}

pub fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidNativeManifest;
    return value.object.get(name) orelse error.InvalidNativeManifest;
}
pub fn string(value: Value, name: []const u8) ![]const u8 {
    const item = try field(value, name);
    if (item != .string) return error.InvalidNativeManifest;
    return item.string;
}
fn object(value: Value, count: usize) !void {
    if (value != .object or value.object.count() != count) return error.InvalidNativeManifest;
}
fn equal(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidNativeManifest;
}
fn hex(bytes: []const u8, count: usize) !void {
    if (bytes.len != count) return error.InvalidNativeManifest;
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidNativeManifest;
}

pub fn verifyGitlink(output: []const u8, revision: []const u8, path: []const u8) !void {
    var bytes: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&bytes, "160000 commit {s}\t{s}", .{ revision, path });
    if (!std.mem.eql(u8, std.mem.trim(u8, output, "\r\n"), expected)) return error.UnexpectedNativeGitlink;
}

pub fn verifyHeader(bytes: []const u8, expected: []const u8) !void {
    try hex(expected, 64);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\r' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            hash.update(bytes[start..index]);
            start = index + 1;
        }
    }
    hash.update(bytes[start..]);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected)) return error.NativeHeaderMismatch;
}

pub fn visualStudio(version: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return error.UnsupportedVisualStudio;
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return error.UnsupportedVisualStudio;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return error.UnsupportedVisualStudio;
        count += 1;
    }
    if (count == 0 or count > 3) return error.UnsupportedVisualStudio;
    if (std.mem.eql(u8, major, "17")) return "Visual Studio 17 2022";
    if (std.mem.eql(u8, major, "18")) return "Visual Studio 18 2026";
    return error.UnsupportedVisualStudio;
}

pub fn packageNameEqual(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, b| {
        const left = if (a == '_' or a == '.') '-' else std.ascii.toLower(a);
        const right = if (b == '_' or b == '.') '-' else std.ascii.toLower(b);
        if (left != right) return false;
    }
    return true;
}

/// Upstream returns exit zero for failed individual tests. Require exactly one
/// nonempty complete summary and every reported test to have succeeded.
pub fn verifyUpstream(output: []const u8) !u32 {
    var count: ?u32 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const full = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, full, "Finished ")) continue;
        if (count != null) return error.NativeTestsFailed;
        const remaining = full["Finished ".len..];
        const total_end = std.mem.indexOf(u8, remaining, " tests in ") orelse return error.NativeTestsFailed;
        const total = std.fmt.parseInt(u32, remaining[0..total_end], 10) catch return error.NativeTestsFailed;
        if (total == 0 or total > 10000) return error.NativeTestsFailed;
        const line = remaining;
        const success_start = (std.mem.indexOf(u8, line, "Succeeded: ") orelse return error.NativeTestsFailed) + "Succeeded: ".len;
        const success_end = std.mem.indexOf(u8, line[success_start..], ". Failed: ") orelse return error.NativeTestsFailed;
        const succeeded = std.fmt.parseInt(u32, line[success_start..][0..success_end], 10) catch return error.NativeTestsFailed;
        if (succeeded != total or !std.mem.eql(u8, line[success_start + success_end ..], ". Failed: 0.")) return error.NativeTestsFailed;
        count = total;
    }
    return count orelse error.NativeTestsFailed;
}

const Probe = struct {
    cycles: u32,
    binary_messages: u32,
    deletion_barriers: u32,
    drained_receipts: u32,
    framed_messages: u32,
    cancelled_assemblies: u32,
    native_disconnects: u32,
    cancelled_offers: u32,
    incoming_channel_overflows: u32,
    zig_allocation_leaks: u32,
    finalized_peers: u32,
    owner_ticks_while_closing: u32,
    graceful_closes: u32,
    backpressure_checks: u32,
    reused_connection_slots: u32,
};
pub const expected_probe: Probe = .{
    .cycles = 3,
    .binary_messages = 384,
    .deletion_barriers = 3,
    .drained_receipts = 384,
    .framed_messages = 771,
    .cancelled_assemblies = 3,
    .native_disconnects = 3,
    .cancelled_offers = 16,
    .incoming_channel_overflows = 1,
    .zig_allocation_leaks = 0,
    .finalized_peers = 42,
    .owner_ticks_while_closing = 9,
    .graceful_closes = 1,
    .backpressure_checks = 1,
    .reused_connection_slots = 40,
};

pub fn verifyProbe(allocator: Allocator, output: []const u8) !void {
    var summaries: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "{\"cycles\":")) continue;
        if (summaries != 0 or line.len > 4096) return error.NativeProbeFailed;
        const parsed = std.json.parseFromSliceLeaky(Probe, allocator, line, .{ .duplicate_field_behavior = .@"error" }) catch return error.NativeProbeFailed;
        if (!std.meta.eql(parsed, expected_probe)) return error.NativeProbeFailed;
        summaries += 1;
    }
    if (summaries != 1 or std.mem.indexOf(u8, output, "10/10 tests passed") == null) return error.NativeProbeFailed;
}
