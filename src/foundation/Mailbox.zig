const std = @import("std");

/// Bounded thread-safe transfer queue using the pinned std.Io implementation.
/// Initialize at its final address and keep it there until all users finish.
/// Drain owned messages after close. Copying a live mailbox is invalid.
pub fn Mailbox(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or capacity > 65_536 or @sizeOf(T) == 0) {
        @compileError("Mailbox requires a nonempty element and 1 through 65536 slots");
    }
    return struct {
        storage: [capacity]T = undefined,
        queue: ?std.Io.Queue(T) = null,

        pub fn init(self: *@This()) error{AlreadyInitialized}!void {
            if (self.queue != null) return error.AlreadyInitialized;
            self.queue = .init(&self.storage);
        }

        /// A full or closed queue retains ownership with the caller.
        /// Uses min=0: does not wait for a consumer to make space.
        pub fn send(self: *@This(), io: std.Io, pending: *?T) error{ NotInitialized, EmptyTransfer, Closed, QueueFull }!void {
            const queue = if (self.queue) |*queue| queue else return error.NotInitialized;
            const value = pending.* orelse return error.EmptyTransfer;
            if (try queue.putUncancelable(io, &.{value}, 0) == 0) return error.QueueFull;
            pending.* = null;
        }

        /// Null means open and empty. Closed is returned only after draining.
        /// Uses min=0: does not wait for a producer to supply a message.
        pub fn receive(self: *@This(), io: std.Io) error{ NotInitialized, Closed }!?T {
            const queue = if (self.queue) |*queue| queue else return error.NotInitialized;
            var output: [1]T = undefined;
            const count = try queue.getUncancelable(io, &output, 0);
            return if (count == 0) null else output[0];
        }

        /// Worker-side wait for one message or closure. Do not call on an owner
        /// that must keep ticking. Queued values drain before Closed is returned.
        pub fn waitReceive(self: *@This(), io: std.Io) error{ NotInitialized, Closed }!T {
            const queue = if (self.queue) |*queue| queue else return error.NotInitialized;
            var output: [1]T = undefined;
            const count = try queue.getUncancelable(io, &output, 1);
            std.debug.assert(count == 1);
            return output[0];
        }

        /// Idempotent. Already queued messages still belong to the receiver.
        pub fn close(self: *@This(), io: std.Io) void {
            if (self.queue) |*queue| queue.close(io);
        }
    };
}

test "mailbox moves only accepted messages and drains after close" {
    var mailbox: Mailbox(u32, 2) = .{};
    const io = std.testing.io;
    var pending: ?u32 = 1;
    try std.testing.expectError(error.NotInitialized, mailbox.send(io, &pending));
    try std.testing.expectError(error.NotInitialized, mailbox.receive(io));
    try std.testing.expectError(error.NotInitialized, mailbox.waitReceive(io));
    try mailbox.init();
    try std.testing.expectError(error.AlreadyInitialized, mailbox.init());
    try std.testing.expectEqual(null, try mailbox.receive(io));
    try mailbox.send(io, &pending);
    try std.testing.expectEqual(null, pending);
    try std.testing.expectError(error.EmptyTransfer, mailbox.send(io, &pending));
    pending = 2;
    try mailbox.send(io, &pending);
    pending = 3;
    try std.testing.expectError(error.QueueFull, mailbox.send(io, &pending));
    try std.testing.expectEqual(@as(?u32, 3), pending);
    try std.testing.expectEqual(@as(?u32, 1), try mailbox.receive(io));
    try mailbox.send(io, &pending);
    mailbox.close(io);
    mailbox.close(io);
    pending = 4;
    try std.testing.expectError(error.Closed, mailbox.send(io, &pending));
    try std.testing.expectEqual(@as(?u32, 4), pending);
    try std.testing.expectEqual(@as(u32, 2), try mailbox.waitReceive(io));
    try std.testing.expectEqual(@as(?u32, 3), try mailbox.receive(io));
    try std.testing.expectError(error.Closed, mailbox.receive(io));
    try std.testing.expectError(error.Closed, mailbox.waitReceive(io));
}
