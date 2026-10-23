const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Reply = struct {
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: Reply) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

fn invoke(directory: Io.Dir, arguments: []const []const u8, expected: u8) !Reply {
    const executable = try Io.Dir.cwd().realPathFileAlloc(testing.io, @import("identity_test_options").executable, testing.allocator);
    defer testing.allocator.free(executable);
    const cwd = try directory.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);
    const argv = try std.mem.concat(testing.allocator, []const u8, &.{ &.{executable}, arguments });
    defer testing.allocator.free(argv);
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    errdefer testing.allocator.free(result.stdout);
    errdefer testing.allocator.free(result.stderr);
    const code = switch (result.term) {
        .exited => |code| code,
        else => return error.IdentityCliTerminated,
    };
    if (code != expected) return error.UnexpectedIdentityCliStatus;
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn pin(output: []const u8) ![64]u8 {
    const prefix = "Fingerprint ";
    const start = (std.mem.indexOf(u8, output, prefix) orelse return error.MissingPublicFingerprint) + prefix.len;
    if (output.len <= start + 64 or output[start + 64] != '\n') return error.InvalidPublicFingerprint;
    var decoded: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, output[start..][0..64]);
    return output[start..][0..64].*;
}

test "identity CLI persists across processes and restores a private backup" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const initial = try invoke(temporary.dir, &.{ "identity", "init", "--directory", "keys" }, 0);
    defer initial.deinit();
    const first = try pin(initial.stdout);
    const shown = try invoke(temporary.dir, &.{ "identity", "show", "--directory", "keys" }, 0);
    defer shown.deinit();
    try testing.expect(std.mem.eql(u8, initial.stdout, shown.stdout));
    const wrong = try invoke(temporary.dir, &.{ "identity", "rotate", "--directory", "keys", "--expected", "0000000000000000000000000000000000000000000000000000000000000000" }, 1);
    defer wrong.deinit();
    try testing.expect(std.mem.indexOf(u8, wrong.stderr, "KeyStoreFingerprintMismatch") != null);
    const rotated = try invoke(temporary.dir, &.{ "identity", "rotate", "--directory", "keys", "--expected", &first }, 0);
    defer rotated.deinit();
    try testing.expect(!std.mem.eql(u8, &first, &(try pin(rotated.stdout))));
    const backup = try invoke(temporary.dir, &.{ "identity", "backup", "--directory", "keys", "--destination", "saved" }, 0);
    defer backup.deinit();
    const restored = try invoke(temporary.dir, &.{ "identity", "show", "--directory", "saved" }, 0);
    defer restored.deinit();
    try testing.expect(std.mem.eql(u8, rotated.stdout, restored.stdout));
    const refused = try invoke(temporary.dir, &.{ "identity", "init", "--directory", "keys" }, 1);
    defer refused.deinit();
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "KeyStoreDirectoryNotEmpty") != null);
}

test "identity CLI inspects and recovers partial tails but preserves full corruption" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const initial = try invoke(temporary.dir, &.{ "identity", "init", "--directory", "keys" }, 0);
    defer initial.deinit();
    const expected = try pin(initial.stdout);
    const original_size = (try temporary.dir.statFile(testing.io, "keys/operator.keys", .{})).size;
    {
        const file = try temporary.dir.openFile(testing.io, "keys/operator.keys", .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, "incomplete append", original_size);
        try file.sync(testing.io);
    }
    const blocked = try invoke(temporary.dir, &.{ "identity", "show", "--directory", "keys" }, 1);
    defer blocked.deinit();
    try testing.expect(std.mem.indexOf(u8, blocked.stderr, "KeyStoreRecoveryRequired") != null);
    const inspected = try invoke(temporary.dir, &.{ "identity", "inspect", "--directory", "keys" }, 0);
    defer inspected.deinit();
    try testing.expectEqualSlices(u8, &expected, &(try pin(inspected.stdout)));
    try testing.expect(std.mem.indexOf(u8, inspected.stdout, "Uncommitted bytes 17") != null);
    const recovered = try invoke(temporary.dir, &.{ "identity", "recover", "--directory", "keys", "--expected", &expected }, 0);
    defer recovered.deinit();
    try testing.expect(std.mem.indexOf(u8, recovered.stdout, "Discarded uncommitted bytes 17") != null);
    try testing.expectEqual(original_size, (try temporary.dir.statFile(testing.io, "keys/operator.keys", .{})).size);
    {
        const file = try temporary.dir.openFile(testing.io, "keys/operator.keys", .{ .mode = .read_write });
        defer file.close(testing.io);
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(testing.io, &byte, original_size - 1);
        byte[0] ^= 1;
        try file.writePositionalAll(testing.io, &byte, original_size - 1);
        try file.sync(testing.io);
    }
    const corrupt = try invoke(temporary.dir, &.{ "identity", "recover", "--directory", "keys", "--expected", &expected }, 1);
    defer corrupt.deinit();
    try testing.expect(std.mem.indexOf(u8, corrupt.stderr, "CorruptKeyStore") != null);
    try testing.expectEqual(original_size, (try temporary.dir.statFile(testing.io, "keys/operator.keys", .{})).size);
}

test "identity help and invalid mutations do not create a default store" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const help = try invoke(temporary.dir, &.{ "identity", "--help" }, 0);
    defer help.deinit();
    try testing.expect(std.mem.indexOf(u8, help.stdout, "identity rotate|recover") != null);
    const invalid = try invoke(temporary.dir, &.{ "identity", "rotate" }, 2);
    defer invalid.deinit();
    try testing.expectError(error.FileNotFound, temporary.dir.access(testing.io, ".shulvyr", .{}));
}
