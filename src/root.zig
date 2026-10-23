const std = @import("std");

pub const version = @import("build_options").version;
pub const binary = @import("foundation/binary.zig");
pub const nbt = @import("foundation/nbt.zig");
pub const Uuid = @import("foundation/Uuid.zig");
pub const Vec3 = @import("math/Vec3.zig");
pub const Aabb = @import("math/Aabb.zig");
pub const VoxelRay = @import("math/VoxelRay.zig");
pub const Pool = @import("foundation/Pool.zig").Pool;
pub const Queue = @import("foundation/Queue.zig").Queue;
pub const Mailbox = @import("foundation/Mailbox.zig").Mailbox;
pub const OwnedBytes = @import("foundation/OwnedBytes.zig");
pub const coordinates = @import("math/coordinates.zig");
pub const ResourceKey = @import("registry/ResourceKey.zig");
pub const catalog = @import("registry/catalog.zig");
pub const BlockState = @import("registry/BlockState.zig");
pub const BlockPalette = @import("registry/BlockPalette.zig");
pub const TickClock = @import("simulation/TickClock.zig");
pub const Scheduler = @import("simulation/Scheduler.zig").Scheduler;
pub const Runtime = @import("simulation/Runtime.zig");
pub const JobStamp = @import("simulation/JobStamp.zig").JobStamp;
pub const StampedBytes = @import("simulation/StampedBytes.zig").StampedBytes;
pub const framing = @import("transport/framing.zig");
pub const TransportSession = @import("transport/Session.zig");
pub const FrameSink = @import("transport/FrameSink.zig");
pub const Outbox = @import("transport/Outbox.zig").Outbox;
pub const outbound = @import("transport/Outbox.zig");
pub const Inbox = @import("transport/Inbox.zig").Inbox;
pub const inbound = @import("transport/Inbox.zig");
pub const cli = @import("operator/cli.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("math/math_test.zig");
    _ = @import("simulation/job_test.zig");
    _ = @import("registry/registry_test.zig");
    _ = @import("registry/block_test.zig");
    _ = @import("registry/palette_test.zig");
    _ = @import("transport/framing_test.zig");
    _ = @import("transport/outbox_test.zig");
    _ = @import("transport/inbox_test.zig");
}
