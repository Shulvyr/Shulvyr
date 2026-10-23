const std = @import("std");

/// Metadata for validating results before the world owner applies them.
/// The owner must resolve a live world before supplying its current stamp.
/// Payload allocation and lifetime remain the job producer's responsibility.
pub fn JobStamp(comptime WorldHandle: type) type {
    return struct {
        world: WorldHandle,
        revision: u64,

        pub fn isCurrent(self: @This(), current: @This()) bool {
            return std.meta.eql(self.world, current.world) and self.revision == current.revision;
        }
    };
}

test "world identity, generation and revision changes reject results" {
    const Handle = @import("../foundation/Pool.zig").Pool(u8).Handle;
    const Stamp = JobStamp(Handle);
    const stamp: Stamp = .{ .world = .{ .owner = 1, .index = 0, .generation = 1 }, .revision = 10 };
    try std.testing.expect(stamp.isCurrent(stamp));
    var current = stamp;
    current.revision += 1;
    try std.testing.expect(!stamp.isCurrent(current));
    current = stamp;
    current.world.generation += 1;
    try std.testing.expect(!stamp.isCurrent(current));
    current = stamp;
    current.world.owner += 1;
    try std.testing.expect(!stamp.isCurrent(current));
    current = stamp;
    current.world.index += 1;
    try std.testing.expect(!stamp.isCurrent(current));
}
