const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Workspace = @This();

directory: Io.Dir,
path: []const u8,
lock: Io.File,

/// Owns only a named child of the repository's work directory. Existing
/// directories need a matching marker before any build output is overwritten.
/// Links are refused at owned directory and log boundaries. This coordinates
/// cooperating local invocations, it does not sandbox native build scripts.
pub fn open(allocator: Allocator, io: Io, name: []const u8, manifest_hash: []const u8) !Workspace {
    return openIn(allocator, io, Io.Dir.cwd(), name, manifest_hash);
}

pub fn openIn(allocator: Allocator, io: Io, cwd: Io.Dir, name: []const u8, manifest_hash: []const u8) !Workspace {
    try validName(name);
    const root = try cwd.realPathFileAlloc(io, ".", allocator);
    try makeDirectory(cwd, io, "work");
    const work = try cwd.realPathFileAlloc(io, "work", allocator);
    try beneath(allocator, root, work);
    var private = try cwd.openDir(io, work, .{});
    defer private.close(io);
    var created = true;
    private.createDir(io, name, permissions(true)) catch |err| switch (err) {
        error.PathAlreadyExists => created = false,
        else => return err,
    };
    try directoryKind(private, io, name);
    const path = try private.realPathFileAlloc(io, name, allocator);
    try beneath(allocator, work, path);
    var directory = try private.openDir(io, name, .{});
    errdefer directory.close(io);
    const marker = try std.fmt.allocPrint(allocator, "Shulvyr native workspace 1\n{s}\n", .{manifest_hash});
    if (created) {
        try directory.writeFile(io, .{ .sub_path = ".shulvyr-native", .data = marker, .flags = .{ .exclusive = true, .permissions = permissions(false) } });
    } else {
        try fileKind(directory, io, ".shulvyr-native");
        const actual = try directory.readFileAlloc(io, ".shulvyr-native", allocator, .limited(256));
        if (!std.mem.eql(u8, marker, actual)) return error.UnownedNativeWorkspace;
    }
    if (directory.statFile(io, "workspace.lock", .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .file) return error.UnsafeNativePath;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const lock = try directory.createFile(io, "workspace.lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = permissions(false) });
    return .{ .directory = directory, .path = path, .lock = lock };
}

pub fn close(self: *Workspace, io: Io) void {
    self.lock.close(io);
    self.directory.close(io);
    self.* = undefined;
}

pub fn child(self: *Workspace, allocator: Allocator, io: Io, name: []const u8) ![]const u8 {
    try validName(name);
    try makeDirectory(self.directory, io, name);
    const result = try self.directory.realPathFileAlloc(io, name, allocator);
    try beneath(allocator, self.path, result);
    return result;
}

fn makeDirectory(parent: Io.Dir, io: Io, path: []const u8) !void {
    parent.createDir(io, path, permissions(true)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try directoryKind(parent, io, path);
}

pub fn write(self: *Workspace, io: Io, name: []const u8, bytes: []const u8) !void {
    if (self.directory.statFile(io, name, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .file) return error.UnsafeNativePath;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try self.directory.writeFile(io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = permissions(false) } });
}
fn directoryKind(parent: Io.Dir, io: Io, path: []const u8) !void {
    if ((try parent.statFile(io, path, .{ .follow_symlinks = false })).kind != .directory) return error.UnsafeNativePath;
}
pub fn fileKind(parent: Io.Dir, io: Io, path: []const u8) !void {
    if ((try parent.statFile(io, path, .{ .follow_symlinks = false })).kind != .file) return error.UnsafeNativePath;
}
pub fn permissions(directory: bool) Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return .fromMode(if (directory) 0o700 else 0o600);
}
pub fn validName(name: []const u8) !void {
    if (name.len == 0 or name.len > 48 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidNativeWorkspaceName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidNativeWorkspaceName;
}
pub fn beneath(allocator: Allocator, parent: []const u8, child_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(parent) or !std.fs.path.isAbsolute(child_path)) return error.UnsafeNativePath;
    const relative = try std.fs.path.relativeAlloc(allocator, parent, null, parent, child_path);
    defer allocator.free(relative);
    if (relative.len == 0 or std.mem.eql(u8, relative, ".") or std.fs.path.isAbsolute(relative)) return error.UnsafeNativePath;
    var parts = std.mem.tokenizeAny(u8, relative, "/\\");
    if (std.mem.eql(u8, parts.next() orelse return error.UnsafeNativePath, "..")) return error.UnsafeNativePath;
}
