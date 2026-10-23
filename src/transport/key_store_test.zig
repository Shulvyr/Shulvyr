const std = @import("std");
const Store = @import("identity/KeyStore.zig");
const Record = @import("identity/key_record.zig");
const Private = @import("identity/private_file.zig");
const Io = std.Io;
const io = std.testing.io;
const expect = std.testing.expect;
// Unexpected successful owners are closed without formatting private fields.
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |returned| {
        const T = @TypeOf(returned);
        if (T == Store) {
            var owner = returned;
            owner.close(io);
        } else if (T == Store.Loaded) {
            var owner = returned;
            owner.deinit();
        } else if (@typeInfo(T) == .@"struct") {
            if (@hasField(T, "loaded")) {
                var owner = returned;
                owner.loaded.deinit();
            }
        }
        return error.ExpectedKeyStoreFailure;
    } else |actual| {
        if (actual != expected) {
            std.debug.print("expected {s}, received {s}\n", .{ @errorName(expected), @errorName(actual) });
            return error.UnexpectedKeyStoreFailure;
        }
    }
}

test "key store requires a stable opened parent and rejects closed owners" {
    try expectError(error.KeyStoreParentMustBeOpen, Store.initialize(io, .cwd(), "keys", .{}));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    store.close(io);
    store.close(io);
    try expectError(error.KeyStoreClosed, store.load(io));
}

test "directory synchronization accepts lookup-only parent capabilities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var parent = try temporary.dir.openDir(io, ".", .{});
    defer parent.close(io);
    try Private.syncDirectory(io, parent);
    var store = try Store.initialize(io, parent, "keys", .{});
    defer store.close(io);
    var loaded = try store.load(io);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.metadata.generation);
}

test "operator key store survives reopen and rotates with a pinned identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    try std.testing.expectEqual(@as(u64, 1), original.metadata.generation);
    store.close(io);
    store = try Store.open(io, temporary.dir, "keys", .{});
    var restored = try store.load(io);
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, &original.metadata.fingerprint, &restored.metadata.fingerprint);
    var rotated = try store.rotate(io, restored.metadata.fingerprint);
    defer rotated.deinit();
    try std.testing.expectEqual(@as(u64, 2), rotated.metadata.generation);
    try std.testing.expect(!std.mem.eql(u8, &rotated.metadata.fingerprint, &restored.metadata.fingerprint));
}

test "operator store refuses another live owner and never reinitializes existing data" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var opened = Store.open(io, temporary.dir, "keys", .{});
    if (opened) |*second| {
        second.close(io);
        return error.ExpectedExclusiveStore;
    } else |err| try expect(err == error.KeyStoreBusy or err == error.WouldBlock);
    store.close(io);
    try expectError(error.KeyStoreDirectoryNotEmpty, Store.initialize(io, temporary.dir, "keys", .{}));
    var unrelated = try Private.directory(io, temporary.dir, "unrelated", true);
    defer unrelated.close(io);
    try unrelated.writeFile(io, .{ .sub_path = "keep.txt", .data = "preserve user data" });
    try expectError(error.KeyStoreDirectoryNotEmpty, Store.initialize(io, temporary.dir, "unrelated", .{}));
    const preserved = try temporary.dir.readFileAlloc(io, "unrelated/keep.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("preserve user data", preserved);
}

test "rotation pins and capacity fail before mutating the store" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{ .records = 2 });
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    const before = (try store.file.stat(io)).size;
    try expectError(error.KeyStoreFingerprintMismatch, store.rotate(io, @splat(0)));
    try std.testing.expectEqual(before, (try store.file.stat(io)).size);
    var current = try store.rotate(io, original.metadata.fingerprint);
    defer current.deinit();
    try expectError(error.KeyStoreFull, store.rotate(io, current.metadata.fingerprint));
    try std.testing.expectEqual(@as(u64, Record.header.len + 2 * Record.frame_bytes), (try store.file.stat(io)).size);
}

test "backup restores the earlier key after the source rotates" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    const copied = try store.backup(io, temporary.dir, "backup");
    try std.testing.expectEqualSlices(u8, &copied.fingerprint, &original.metadata.fingerprint);
    var rotated = try store.rotate(io, original.metadata.fingerprint);
    defer rotated.deinit();
    var backup = try Store.open(io, temporary.dir, "backup", .{});
    defer backup.close(io);
    var restored = try backup.load(io);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 1), restored.metadata.generation);
    try std.testing.expectEqualSlices(u8, &restored.metadata.fingerprint, &original.metadata.fingerprint);
    const signature = try restored.key.sign("backup signing check", null);
    const public = try original.key.publicKey();
    try public.verify("backup signing check", &signature);
    try expectError(error.KeyStoreDirectoryNotEmpty, store.backup(io, temporary.dir, "backup"));
}

test "partial tails require an explicit matching recovery pin" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    const length = (try store.file.stat(io)).size;
    try store.file.writePositionalAll(io, "partial pending frame", length);
    try expectError(error.KeyStoreRecoveryRequired, store.load(io));
    try expectError(error.KeyStoreRecoveryRequired, store.rotate(io, original.metadata.fingerprint));
    try expectError(error.KeyStoreRecoveryRequired, store.backup(io, temporary.dir, "backup"));
    try expectError(error.KeyStoreFingerprintMismatch, store.recover(io, @splat(0)));
    const inspection = try store.inspect(io);
    try std.testing.expectEqual(@as(u16, "partial pending frame".len), inspection.uncommitted_bytes);
    var recovered = try store.recover(io, original.metadata.fingerprint);
    defer recovered.loaded.deinit();
    try std.testing.expectEqualSlices(u8, &recovered.loaded.metadata.fingerprint, &original.metadata.fingerprint);
    try std.testing.expectEqual(length, (try store.file.stat(io)).size);
    try expectError(error.KeyStoreRecoveryNotNeeded, store.recover(io, original.metadata.fingerprint));
}

test "complete corrupt frames and unknown headers are never truncated" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    var frame: [Record.frame_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &frame);
    _ = try Record.encode(&original.key, 2, &frame);
    frame[159] ^= 1;
    const length = (try store.file.stat(io)).size;
    try store.file.writePositionalAll(io, &frame, length);
    try expectError(error.CorruptKeyStore, store.recover(io, original.metadata.fingerprint));
    try std.testing.expectEqual(length + frame.len, (try store.file.stat(io)).size);
    try store.file.setLength(io, length);
    try store.file.writePositionalAll(io, &.{2}, 8);
    try expectError(error.UnsupportedKeyStore, store.load(io));
}

test "malformed records reject invalid scalar, generation and reserved fields" {
    var key = try @import("identity/OperatorKey.zig").generate(io);
    defer key.deinit();
    var frame: [Record.frame_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &frame);
    _ = try Record.encode(&key, 1, &frame);
    try Record.validate(&frame, 1);
    try expectError(error.CorruptKeyStore, Record.validate(&frame, 2));
    frame[88] = 1;
    try expectError(error.CorruptKeyStore, Record.validate(&frame, 1));
    frame[88] = 0;
    for ([_]u8{ 0, 255 }) |byte| {
        @memset(frame[8..56], byte);
        var checksum: std.crypto.hash.sha2.Sha256 = .init(.{});
        checksum.update(Record.header);
        checksum.update(frame[0..96]);
        @memcpy(frame[96..128], &checksum.finalResult());
        var commit: std.crypto.hash.sha2.Sha256 = .init(.{});
        commit.update("Shulvyr operator key commit v1\x00");
        commit.update(frame[0..128]);
        @memcpy(frame[128..160], &commit.finalResult());
        try expectError(error.CorruptKeyStore, Record.validate(&frame, 1));
    }
}

test "record encoding preflights key lifetime, generation and output aliases" {
    var key = try @import("identity/OperatorKey.zig").generate(io);
    defer key.deinit();
    const public = try key.publicKey();
    try expectError(error.AliasedBuffer, Record.encode(&key, 1, @ptrCast(&key)));
    const signature = try key.sign("alias failure preserved the owner", null);
    try public.verify("alias failure preserved the owner", &signature);
    var frame: [Record.frame_bytes]u8 = @splat(0xa5);
    defer std.crypto.secureZero(u8, &frame);
    try expectError(error.InvalidKeyGeneration, Record.encode(&key, 0, &frame));
    key.deinit();
    try expectError(error.OperatorKeyDestroyed, Record.encode(&key, 1, &frame));
    try expect(std.mem.allEqual(u8, &frame, 0xa5));
}

test "store limits and incomplete first creation do not generate another identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try expectError(error.InvalidKeyStoreLimits, Store.initialize(io, temporary.dir, "bad", .{ .records = 0 }));
    try expectError(error.InvalidKeyStoreName, Store.initialize(io, temporary.dir, "../escape", .{}));
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    try store.file.setLength(io, Record.header.len + 100);
    try expectError(error.KeyStoreNoCommittedKey, store.load(io));
    try expectError(error.KeyStoreNoCommittedKey, store.recover(io, @splat(0)));
    try std.testing.expectEqual(@as(u64, Record.header.len + 100), (try store.file.stat(io)).size);
    try store.file.setLength(io, Record.header.len + @as(u64, 4096) * Record.frame_bytes + 1);
    try expectError(error.KeyStoreLimit, store.load(io));
}

test "hard links are refused before reading private records" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    store.close(io);
    if (@import("builtin").os.tag == .windows) {
        const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const source = try std.fs.path.join(std.testing.allocator, &.{ root, "keys/operator.keys" });
        defer std.testing.allocator.free(source);
        const alias = try std.fs.path.join(std.testing.allocator, &.{ root, "alias" });
        defer std.testing.allocator.free(alias);
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, source);
        defer std.testing.allocator.free(source_w);
        const alias_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, alias);
        defer std.testing.allocator.free(alias_w);
        if (!CreateHardLinkW(alias_w, source_w, null).toBool()) return error.HardLinkFixtureFailed;
    } else try temporary.dir.hardLink("keys/operator.keys", temporary.dir, "alias", io, .{});
    try expectError(error.InsecureKeyStore, Store.open(io, temporary.dir, "keys", .{}));
}

extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn SetNamedSecurityInfoW([*:0]u16, c_int, u32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) u32;

test "broadened POSIX permissions or Windows DACL are refused" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    store.close(io);
    if (@import("builtin").os.tag == .windows) {
        const path = try temporary.dir.realPathFileAlloc(io, "keys/operator.keys", std.testing.allocator);
        defer std.testing.allocator.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
        defer std.testing.allocator.free(wide);
        try std.testing.expectEqual(@as(u32, 0), SetNamedSecurityInfoW(wide, 1, 0x80000004, null, null, null, null));
    } else {
        const file = try temporary.dir.openFile(io, "keys/operator.keys", .{ .mode = .read_write });
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o644));
    }
    try expectError(error.InsecureKeyStore, Store.open(io, temporary.dir, "keys", .{}));
}

threadlocal var active_fault: ?*Fault = null;
const Fault = struct {
    parent: Io = io,
    target: Io.File,
    vtable: Io.VTable = undefined,
    remaining: ?usize = null,
    fail_sync: ?u32 = null,
    syncs: u32 = 0,

    fn activate(self: *Fault) Io {
        std.debug.assert(active_fault == null);
        self.vtable = self.parent.vtable.*;
        self.vtable.fileWritePositional = write;
        self.vtable.fileSync = sync;
        active_fault = self;
        return .{ .userdata = self.parent.userdata, .vtable = &self.vtable };
    }
    fn deactivate(self: *Fault) void {
        if (active_fault == self) active_fault = null;
    }
    fn write(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const state = active_fault orelse unreachable;
        if (file.handle == state.target.handle) if (state.remaining) |remaining| {
            std.debug.assert(header.len == 0 and data.len == 1 and splat == 1);
            if (remaining == 0) return error.NoSpaceLeft;
            const count = try state.parent.vtable.fileWritePositional(userdata, file, header, &.{data[0][0..@min(remaining, data[0].len)]}, 1, offset);
            state.remaining = remaining - count;
            return count;
        };
        return state.parent.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
    }
    fn sync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const state = active_fault orelse unreachable;
        if (file.handle == state.target.handle) {
            state.syncs += 1;
            if (state.fail_sync == state.syncs) return error.InputOutput;
        }
        return state.parent.vtable.fileSync(userdata, file);
    }
};

test "short writes and failed prepare sync preserve the committed key for recovery" {
    for (0..3) |scenario| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var store = try Store.initialize(io, temporary.dir, "keys", .{});
        defer store.close(io);
        var original = try store.load(io);
        defer original.deinit();
        var fault: Fault = .{ .target = store.file, .remaining = if (scenario == 0) 64 else if (scenario == 1) 144 else null, .fail_sync = if (scenario == 2) 1 else null };
        const broken = fault.activate();
        defer fault.deactivate();
        try expectError(error.KeyStoreCommitUncertain, store.rotate(broken, original.metadata.fingerprint));
        try expectError(error.KeyStoreCommitUncertain, store.load(io));
        fault.deactivate();
        store.close(io);
        store = try Store.open(io, temporary.dir, "keys", .{});
        try expectError(error.KeyStoreRecoveryRequired, store.load(io));
        var recovered = try store.recover(io, original.metadata.fingerprint);
        defer recovered.loaded.deinit();
        try expect(recovered.discarded_bytes > 0);
        try std.testing.expectEqualSlices(u8, &recovered.loaded.metadata.fingerprint, &original.metadata.fingerprint);
    }
}

test "failed final sync reloads the actual complete commit instead of rolling it back" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.initialize(io, temporary.dir, "keys", .{});
    defer store.close(io);
    var original = try store.load(io);
    defer original.deinit();
    var fault: Fault = .{ .target = store.file, .fail_sync = 2 };
    const broken = fault.activate();
    defer fault.deactivate();
    try expectError(error.KeyStoreCommitUncertain, store.rotate(broken, original.metadata.fingerprint));
    fault.deactivate();
    store.close(io);
    store = try Store.open(io, temporary.dir, "keys", .{});
    var actual = try store.load(io);
    defer actual.deinit();
    try std.testing.expectEqual(@as(u64, 2), actual.metadata.generation);
    try expect(!std.mem.eql(u8, &actual.metadata.fingerprint, &original.metadata.fingerprint));
    try expectError(error.KeyStoreFingerprintMismatch, store.recover(io, original.metadata.fingerprint));
}
