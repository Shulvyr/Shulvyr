const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Windows = @import("windows_private.zig");

pub fn validName(name: []const u8) !void {
    if (name.len == 0 or name.len > 240 or !std.unicode.utf8ValidateSlice(name) or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidKeyStoreName;
    for (name) |byte| if (byte < 32 or byte == 127 or std.mem.indexOfScalar(u8, "/\\:\"*?<>|", byte) != null) return error.InvalidKeyStoreName;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.InvalidKeyStoreName;
}

/// Parent is a borrowed, trusted directory capability. Only a single child is
/// accepted. Existing objects are validated, never silently chmodded/re-ACL'd.
pub fn directory(io: Io, parent: Io.Dir, name: []const u8, create: bool) !Io.Dir {
    try validName(name);
    if (parent.handle == Io.Dir.cwd().handle) return error.KeyStoreParentMustBeOpen;
    var result: Io.Dir = switch (builtin.os.tag) {
        .windows => try Windows.openDirectory(parent, name, create),
        .linux => blk: {
            if (create) parent.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            break :blk try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
        },
        else => return error.KeyStorePlatformUnsupported,
    };
    errdefer result.close(io);
    try validate(io, .{ .handle = result.handle, .flags = .{ .nonblocking = false } }, true);
    if (create) try syncDirectory(io, parent);
    return result;
}

pub fn file(io: Io, parent: Io.Dir, name: []const u8, create: bool) !Io.File {
    try validName(name);
    const result = switch (builtin.os.tag) {
        .windows => try Windows.openFile(parent, name, create),
        .linux => if (create) try parent.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true }) else try parent.openFile(io, name, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true }),
        else => return error.KeyStorePlatformUnsupported,
    };
    errdefer result.close(io);
    try validate(io, result, false);
    return result;
}

pub fn validate(io: Io, handle: Io.File, is_directory: bool) !void {
    const stat = try handle.stat(io);
    if (stat.kind != (if (is_directory) Io.File.Kind.directory else Io.File.Kind.file) or (!is_directory and stat.nlink != 1)) return error.InsecureKeyStore;
    switch (builtin.os.tag) {
        .windows => try Windows.validate(handle.handle),
        .linux => {
            if (stat.permissions.toMode() & 0o7777 != (if (is_directory) @as(u32, 0o700) else 0o600)) return error.InsecureKeyStore;
            var owner: std.os.linux.Statx = undefined;
            const result = std.os.linux.statx(handle.handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &owner);
            if (std.posix.errno(result) != .SUCCESS or !owner.mask.UID) return error.KeyStoreAccountUnavailable;
            if (owner.uid != std.os.linux.geteuid()) return error.InsecureKeyStore;
        },
        else => return error.KeyStorePlatformUnsupported,
    }
}

pub fn syncDirectory(io: Io, handle: Io.Dir) !void {
    if (handle.handle == Io.Dir.cwd().handle) return error.KeyStoreParentMustBeOpen;
    switch (builtin.os.tag) {
        .windows => try Windows.syncDirectory(io, handle),
        .linux => {
            // Zig may open a non-iterable parent with O_PATH. Reopen this
            // capability for reading because fsync rejects O_PATH descriptors.
            var readable = try handle.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
            defer readable.close(io);
            try (Io.File{ .handle = readable.handle, .flags = .{ .nonblocking = false } }).sync(io);
        },
        else => return error.KeyStorePlatformUnsupported,
    }
}
