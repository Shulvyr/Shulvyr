const std = @import("std");
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const JobStamp = @import("JobStamp.zig").JobStamp;

/// Immutable job/result bytes tagged for an owner to validate before applying.
/// Do not copy live values. Move them through a mailbox or takeIfCurrent.
pub fn StampedBytes(comptime WorldHandle: type) type {
    return struct {
        stamp: JobStamp(WorldHandle),
        payload: OwnedBytes,
        pending: bool = true,

        pub fn copy(allocator: std.mem.Allocator, stamp: JobStamp(WorldHandle), input: []const u8, max_bytes: usize) !@This() {
            return .{ .stamp = stamp, .payload = try .copy(allocator, input, max_bytes) };
        }

        /// Only the owner calls this after resolving a live world.
        /// Null means unloaded or canceled. Stale results release their payload.
        pub fn takeIfCurrent(self: *@This(), current: ?JobStamp(WorldHandle)) ?OwnedBytes {
            if (!self.pending) return null;
            self.pending = false;
            const live = current orelse {
                self.deinit();
                return null;
            };
            if (!self.stamp.isCurrent(live)) {
                self.deinit();
                return null;
            }
            return self.payload.take();
        }

        pub fn deinit(self: *@This()) void {
            self.pending = false;
            self.payload.deinit();
        }
    };
}

test "owner releases stale, canceled and unloaded result buffers" {
    const Handle = @import("../foundation/Pool.zig").Pool(u8).Handle;
    const Message = StampedBytes(Handle);
    const Stamp = JobStamp(Handle);
    const original: Stamp = .{ .world = .{ .owner = 1, .index = 2, .generation = 3 }, .revision = 4 };
    var generation = original;
    generation.world.generation += 1;
    var revision = original;
    revision.revision += 1;
    var world = original;
    world.world.owner += 1;
    for ([_]?Stamp{ null, generation, revision, world }) |current| {
        var result = try Message.copy(std.testing.allocator, original, "result", 6);
        defer result.deinit();
        try std.testing.expectEqual(null, result.takeIfCurrent(current));
        try std.testing.expectEqual(@as(usize, 0), result.payload.bytes().len);
    }
    var result = try Message.copy(std.testing.allocator, original, "valid", 5);
    defer result.deinit();
    var accepted = result.takeIfCurrent(original).?;
    defer accepted.deinit();
    try std.testing.expectEqualStrings("valid", accepted.bytes());
    try std.testing.expectEqual(@as(usize, 0), result.payload.bytes().len);
    try std.testing.expectEqual(null, result.takeIfCurrent(original));
    var zero_length = try Message.copy(std.testing.failing_allocator, original, "", 0);
    var zero_accepted = zero_length.takeIfCurrent(original).?;
    zero_accepted.deinit();
    try std.testing.expectEqual(null, zero_length.takeIfCurrent(original));
}
