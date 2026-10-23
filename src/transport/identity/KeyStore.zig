const std = @import("std");
const Io = std.Io;
const Key = @import("OperatorKey.zig");
const Private = @import("private_file.zig");
const Record = @import("key_record.zig");
const Store = @This();

pub const file_name = "operator.keys";
pub const Limits = struct {
    records: u32 = 4096,
    fn validate(self: Limits) !void {
        if (self.records == 0 or self.records > 4096) return error.InvalidKeyStoreLimits;
    }
};
pub const Metadata = struct { generation: u64, fingerprint: [32]u8, records: u32 };
pub const Loaded = struct {
    key: Key,
    metadata: Metadata,

    pub fn deinit(self: *Loaded) void {
        self.key.deinit();
    }
    pub fn format(_: *const Loaded, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("LoadedOperatorKey(redacted)");
    }
};

/// Owns directory/file handles and an exclusive store lock. Parent is borrowed
/// and must outlive this owner. Do not copy the owner or call it concurrently.
/// All operations are synchronous management work, never a world/network callback.
parent: Io.Dir,
directory: Io.Dir,
file: Io.File,
limits: Limits,
active: bool = true,
uncertain: bool = false,

pub fn initialize(io: Io, parent: Io.Dir, name: []const u8, limits: Limits) !Store {
    try limits.validate();
    var directory = try Private.directory(io, parent, name, true);
    errdefer directory.close(io);
    var entries = directory.iterate();
    if (try entries.next(io) != null) return error.KeyStoreDirectoryNotEmpty;
    const file = try Private.file(io, directory, file_name, true);
    errdefer file.close(io);
    var result: Store = .{ .parent = parent, .directory = directory, .file = file, .limits = limits };
    try file.writePositionalAll(io, Record.header, 0);
    try file.sync(io);
    var key = try Key.generate(io);
    defer key.deinit();
    _ = try result.append(io, &key, 1, Record.header.len);
    Private.syncDirectory(io, directory) catch return error.KeyStoreCommitUncertain;
    Private.syncDirectory(io, parent) catch return error.KeyStoreCommitUncertain;
    return result;
}

pub fn open(io: Io, parent: Io.Dir, name: []const u8, limits: Limits) !Store {
    try limits.validate();
    var directory = try Private.directory(io, parent, name, false);
    errdefer directory.close(io);
    const file = try Private.file(io, directory, file_name, false);
    return .{ .parent = parent, .directory = directory, .file = file, .limits = limits };
}

pub fn close(self: *Store, io: Io) void {
    if (!self.active) return;
    self.file.close(io);
    self.directory.close(io);
    self.active = false;
}

/// Validates the complete committed prefix before returning an owned key.
/// Incomplete tails require explicit recovery. A reopened complete commit is
/// flushed before use, including after an earlier caller saw uncertain sync.
pub fn load(self: *Store, io: Io) !Loaded {
    var snapshot = try self.scan(io);
    defer snapshot.clear();
    if (snapshot.tail != 0) return error.KeyStoreRecoveryRequired;
    try self.file.sync(io);
    try Private.syncDirectory(io, self.directory);
    try Private.syncDirectory(io, self.parent);
    return snapshot.materialize();
}

pub fn inspect(self: *Store, io: Io) !struct { metadata: Metadata, uncommitted_bytes: u16 } {
    var snapshot = try self.scan(io);
    defer snapshot.clear();
    return .{ .metadata = snapshot.metadata, .uncommitted_bytes = snapshot.tail };
}

/// Rotation retains earlier private records. expected binds the operation to
/// the operator identity actually observed by the caller. Any write/sync error
/// poisons this handle. Close/reopen and inspect the actual committed identity.
pub fn rotate(self: *Store, io: Io, expected: [32]u8) !Loaded {
    var snapshot = try self.scan(io);
    defer snapshot.clear();
    if (snapshot.tail != 0) return error.KeyStoreRecoveryRequired;
    if (!std.mem.eql(u8, &expected, &snapshot.metadata.fingerprint)) return error.KeyStoreFingerprintMismatch;
    if (snapshot.metadata.records == self.limits.records) return error.KeyStoreFull;
    var key = try Key.generate(io);
    defer key.deinit();
    const generation = snapshot.metadata.generation + 1;
    const fingerprint = try self.append(io, &key, generation, snapshot.committed_bytes);
    return .{ .key = key, .metadata = .{ .generation = generation, .fingerprint = fingerprint, .records = snapshot.metadata.records + 1 } };
}

/// Discards only a trailing partial frame after a validated committed prefix.
/// Complete corrupt frames are preserved and refused. A fingerprint mismatch
/// cannot discard a later valid commit. This is logical recovery, not erasure.
pub fn recover(self: *Store, io: Io, expected: [32]u8) !struct { loaded: Loaded, discarded_bytes: u16 } {
    var snapshot = try self.scan(io);
    defer snapshot.clear();
    if (!std.mem.eql(u8, &expected, &snapshot.metadata.fingerprint)) return error.KeyStoreFingerprintMismatch;
    if (snapshot.tail == 0) return error.KeyStoreRecoveryNotNeeded;
    self.uncertain = true;
    self.file.setLength(io, snapshot.committed_bytes) catch return error.KeyStoreCommitUncertain;
    self.file.sync(io) catch return error.KeyStoreCommitUncertain;
    self.uncertain = false;
    return .{ .loaded = try snapshot.materialize(), .discarded_bytes = snapshot.tail };
}

/// Copies the complete history into a new private store without replacing any
/// destination file. Failed destinations remain for explicit operator recovery.
pub fn backup(self: *Store, io: Io, parent: Io.Dir, name: []const u8) !Metadata {
    var snapshot = try self.scan(io);
    defer snapshot.clear();
    if (snapshot.tail != 0) return error.KeyStoreRecoveryRequired;
    try self.file.sync(io);
    try Private.syncDirectory(io, self.directory);
    try Private.syncDirectory(io, self.parent);
    var directory = try Private.directory(io, parent, name, true);
    defer directory.close(io);
    var entries = directory.iterate();
    if (try entries.next(io) != null) return error.KeyStoreDirectoryNotEmpty;
    const target = try Private.file(io, directory, file_name, true);
    defer target.close(io);
    var bytes: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    var offset: u64 = 0;
    while (offset < snapshot.committed_bytes) {
        const count: usize = @intCast(@min(bytes.len, snapshot.committed_bytes - offset));
        if (try self.file.readPositionalAll(io, bytes[0..count], offset) != count) return error.CorruptKeyStore;
        try target.writePositionalAll(io, bytes[0..count], offset);
        offset += count;
    }
    try target.sync(io);
    try Private.syncDirectory(io, directory);
    try Private.syncDirectory(io, parent);
    return snapshot.metadata;
}

fn append(self: *Store, io: Io, key: *const Key, generation: u64, offset: u64) ![32]u8 {
    var frame: [Record.frame_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &frame);
    const fingerprint = try Record.encode(key, generation, &frame);
    self.uncertain = true;
    self.file.writePositionalAll(io, frame[0..Record.record_bytes], offset) catch return error.KeyStoreCommitUncertain;
    self.file.sync(io) catch return error.KeyStoreCommitUncertain;
    self.file.writePositionalAll(io, frame[Record.record_bytes..], offset + Record.record_bytes) catch return error.KeyStoreCommitUncertain;
    self.file.sync(io) catch return error.KeyStoreCommitUncertain;
    self.uncertain = false;
    return fingerprint;
}

const Snapshot = struct {
    secret: [48]u8,
    metadata: Metadata,
    committed_bytes: u64,
    tail: u16,

    fn clear(self: *Snapshot) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
    fn materialize(self: *const Snapshot) !Loaded {
        return .{ .key = try Key.fromSecretScalar(&self.secret), .metadata = self.metadata };
    }
};

fn scan(self: *Store, io: Io) !Snapshot {
    if (!self.active) return error.KeyStoreClosed;
    if (self.uncertain) return error.KeyStoreCommitUncertain;
    try Private.validate(io, self.file, false);
    const size = (try self.file.stat(io)).size;
    const maximum = Record.header.len + @as(u64, self.limits.records) * Record.frame_bytes;
    if (size > maximum) return error.KeyStoreLimit;
    var header: [Record.header.len]u8 = undefined;
    if (try self.file.readPositionalAll(io, &header, 0) != header.len or !std.mem.eql(u8, &header, Record.header)) return error.UnsupportedKeyStore;
    const records: u32 = @intCast((size - header.len) / Record.frame_bytes);
    if (records == 0) return error.KeyStoreNoCommittedKey;
    var frame: [Record.frame_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &frame);
    for (0..records) |index| {
        const offset = header.len + @as(u64, index) * Record.frame_bytes;
        if (try self.file.readPositionalAll(io, &frame, offset) != frame.len) return error.CorruptKeyStore;
        try Record.validate(&frame, index + 1);
    }
    var key = Key.fromSecretScalar(frame[8..56]) catch return error.CorruptKeyStore;
    defer key.deinit();
    const public = try key.publicKey();
    const fingerprint = public.digest();
    if (!std.mem.eql(u8, &fingerprint, frame[56..88])) return error.CorruptKeyStore;
    const committed_bytes = header.len + @as(u64, records) * Record.frame_bytes;
    return .{ .secret = frame[8..56].*, .metadata = .{ .generation = records, .fingerprint = fingerprint, .records = records }, .committed_bytes = committed_bytes, .tail = @intCast(size - committed_bytes) };
}

pub fn format(_: *const Store, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("OperatorKeyStore");
}
