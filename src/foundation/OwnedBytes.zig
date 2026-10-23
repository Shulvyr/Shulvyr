const std = @import("std");
const OwnedBytes = @This();

storage: []u8 = &.{},
allocator: ?std.mem.Allocator = null,

/// Copies a snapshot before the caller reuses its scratch storage.
/// The allocator must outlive the snapshot and support the contexts freeing it.
pub fn copy(allocator: std.mem.Allocator, input: []const u8, max_bytes: usize) !OwnedBytes {
    if (input.len > max_bytes) return error.PayloadTooLarge;
    if (input.len == 0) return .{};
    return .{ .storage = try allocator.dupe(u8, input), .allocator = allocator };
}

pub fn bytes(self: *const OwnedBytes) []const u8 {
    return self.storage;
}

/// Moves ownership and leaves an empty, safely destructible source.
pub fn take(self: *OwnedBytes) OwnedBytes {
    const value = self.*;
    self.* = .{};
    return value;
}

pub fn deinit(self: *OwnedBytes) void {
    if (self.allocator) |allocator| allocator.free(self.storage);
    self.* = .{};
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var value = try copy(allocator, "snapshot", 8);
    defer value.deinit();
    try std.testing.expectEqualStrings("snapshot", value.bytes());
}

test "snapshot owns its bytes after scratch reuse and a move" {
    var scratch: [4]u8 = .{ 1, 2, 3, 4 };
    var source = try copy(std.testing.allocator, &scratch, 4);
    defer source.deinit();
    @memset(&scratch, 0);
    var destination = source.take();
    defer destination.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, destination.bytes());
    try std.testing.expectEqual(@as(usize, 0), source.bytes().len);
    destination.deinit();
    destination.deinit();
}

test "payload limits precede allocation and OOM retains no storage" {
    try std.testing.expectError(error.PayloadTooLarge, copy(std.testing.failing_allocator, "x", 0));
    var empty = try copy(std.testing.failing_allocator, "", 0);
    empty.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
