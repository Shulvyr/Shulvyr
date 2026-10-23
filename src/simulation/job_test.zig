const std = @import("std");
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const Mailbox = @import("../foundation/Mailbox.zig").Mailbox;
const Pool = @import("../foundation/Pool.zig").Pool;
const JobStamp = @import("JobStamp.zig").JobStamp;
const StampedBytes = @import("StampedBytes.zig").StampedBytes;
const Handle = Pool(u8).Handle;
const Stamp = JobStamp(Handle);
const Message = StampedBytes(Handle);
const Channel = Mailbox(Message, 2);
const stamp: Stamp = .{ .world = .{ .owner = 1, .index = 0, .generation = 1 }, .revision = 7 };

/// Test worker only forwards immutable bytes. It never accesses owner state.
const EchoWorker = struct {
    input: *Channel,
    output: *Channel,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    has_pending: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    thread_id: std.atomic.Value(std.Thread.Id) = .init(0),

    fn run(self: *EchoWorker) void {
        self.thread_id.store(std.Thread.getCurrentId(), .release);
        defer self.finished.store(true, .release);
        var pending: ?Message = null;
        defer if (pending) |*message| message.deinit();
        while (!self.stop.load(.acquire)) {
            if (pending == null) {
                pending = self.input.receive(self.io) catch |err| switch (err) {
                    error.Closed => return,
                    error.NotInitialized => {
                        self.failed.store(true, .release);
                        return;
                    },
                };
                self.has_pending.store(pending != null, .release);
            }
            if (pending != null) {
                self.output.send(self.io, &pending) catch |err| switch (err) {
                    error.QueueFull => {},
                    error.Closed => return,
                    error.NotInitialized, error.EmptyTransfer => {
                        self.failed.store(true, .release);
                        return;
                    },
                };
                self.has_pending.store(pending != null, .release);
            }
            std.Thread.yield() catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

fn drain(channel: *Channel, io: std.Io) void {
    channel.close(io);
    while (channel.receive(io) catch |err| switch (err) {
        error.Closed => null,
        error.NotInitialized => unreachable,
    }) |value| {
        var message = value;
        message.deinit();
    }
}

fn checkDeadline(io: std.Io, start: std.Io.Timestamp) !void {
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    if (elapsed > 10 * std.time.ns_per_s) return error.WorkerTestTimeout;
}

test "real worker transfers independent snapshots with bounded bidirectional queues" {
    const io = std.testing.io;
    var input: Channel = .{};
    var output: Channel = .{};
    try input.init();
    try output.init();
    var worker: EchoWorker = .{ .input = &input, .output = &output, .io = io };
    const thread = try std.Thread.spawn(.{}, EchoWorker.run, .{&worker});
    var pending: ?Message = null;
    defer {
        worker.stop.store(true, .release);
        thread.join();
        if (pending) |*message| message.deinit();
        drain(&input, io);
        drain(&output, io);
    }
    var sent: u8 = 0;
    var received: u8 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (received < 64) {
        try checkDeadline(io, start);
        if (worker.failed.load(.acquire)) return error.WorkerFailed;
        if (sent < 64 and pending == null) {
            var scratch: [2]u8 = .{ sent, 255 - sent };
            pending = try Message.copy(std.testing.allocator, stamp, &scratch, 2);
            @memset(&scratch, 0);
        }
        if (pending != null) {
            input.send(io, &pending) catch |err| switch (err) {
                error.QueueFull => {},
                else => return err,
            };
            if (pending == null) sent += 1;
        }
        if (try output.receive(io)) |value| {
            var result = value;
            defer result.deinit();
            var accepted = result.takeIfCurrent(stamp) orelse return error.UnexpectedStaleResult;
            defer accepted.deinit();
            try std.testing.expectEqualSlices(u8, &.{ received, 255 - received }, accepted.bytes());
            try std.testing.expectEqual(null, result.takeIfCurrent(stamp));
            received += 1;
        }
        try std.Thread.yield();
    }
    try std.testing.expectEqual(@as(u8, 64), sent);
    try std.testing.expect(worker.thread_id.load(.acquire) != std.Thread.getCurrentId());
}

test "closing a saturated result queue releases the worker's pending snapshot" {
    const io = std.testing.io;
    var input: Channel = .{};
    var output: Channel = .{};
    try input.init();
    try output.init();
    defer drain(&input, io);
    defer drain(&output, io);
    for (0..2) |_| {
        var queued: ?Message = try Message.copy(std.testing.allocator, stamp, "queued", 6);
        defer if (queued) |*message| message.deinit();
        try output.send(io, &queued);
    }
    var submitted: ?Message = try Message.copy(std.testing.allocator, stamp, "worker", 6);
    defer if (submitted) |*message| message.deinit();
    try input.send(io, &submitted);
    input.close(io);
    var worker: EchoWorker = .{ .input = &input, .output = &output, .io = io };
    const thread = try std.Thread.spawn(.{}, EchoWorker.run, .{&worker});
    defer {
        worker.stop.store(true, .release);
        thread.join();
    }
    const start = std.Io.Clock.awake.now(io);
    while (!worker.has_pending.load(.acquire)) {
        try checkDeadline(io, start);
        if (worker.failed.load(.acquire)) return error.WorkerFailed;
        try std.Thread.yield();
    }
    output.close(io);
    while (!worker.finished.load(.acquire)) {
        try checkDeadline(io, start);
        try std.Thread.yield();
    }
    try std.testing.expect(!worker.failed.load(.acquire));
}

test "closed mailbox retains the sender's owned payload for cleanup" {
    const io = std.testing.io;
    var channel: Channel = .{};
    try channel.init();
    channel.close(io);
    var pending: ?Message = try Message.copy(std.testing.allocator, stamp, "retained", 8);
    defer if (pending) |*message| message.deinit();
    try std.testing.expectError(error.Closed, channel.send(io, &pending));
    try std.testing.expectEqualStrings("retained", pending.?.payload.bytes());
    var moved: OwnedBytes = pending.?.takeIfCurrent(stamp).?;
    moved.deinit();
}
