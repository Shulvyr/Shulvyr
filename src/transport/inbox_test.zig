const std = @import("std");
const incoming = @import("Inbox.zig");
const Inbox = incoming.Inbox;
const Session = @import("Session.zig");
const framing = @import("framing.zig");
const allocator = std.testing.allocator;
const io = std.testing.io;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const id: Session.Id = .{ .owner = 7, .index = 0, .generation = 1 };
const config: incoming.Config = .{ .frame_bytes = 5, .payload_bytes = 10 };

test "provider channel rejection retains its specific session close reason" {
    var inbox: Inbox(2) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    var fixture: Fixture = .{};
    var session = try fixture.session(false);
    try inbox.stop(id, .invalid_channel);
    try expect(try inbox.applyStop(&session));
    try equal(Session.CloseReason.invalid_channel, session.close_reason.?);
}

const Fixture = struct {
    reliable: [32]u8 = @splat(0),
    unreliable: [4]u8 = @splat(0),

    fn session(self: *Fixture, open: bool) !Session {
        var value = try Session.init(id, &self.reliable, &self.unreliable, .{ .frame_bytes = 5, .message_bytes = 32 }, 0, 100);
        if (open) {
            try value.channelOpened(id, .reliable, .required(.reliable), 0);
            try value.channelOpened(id, .unreliable, .required(.unreliable), 0);
        }
        return value;
    }
};

fn cleanup(inbox: anytype) void {
    inbox.stop(id, .requested) catch unreachable;
    _ = inbox.discard(4096) catch unreachable;
    inbox.deinit();
}

test "inbox initialization validates identity and budgets before allocation" {
    var inbox: Inbox(2) = .{};
    try expectError(error.NotInitialized, inbox.status());
    try expectError(error.NotInitialized, inbox.receive());
    try expectError(error.NotInitialized, inbox.post(id, .reliable, &.{ 0, 1 }));
    try expectError(error.NotInitialized, inbox.stop(id, .requested));
    var invalid = id;
    invalid.owner = 0;
    try expectError(error.InvalidIdentity, inbox.init(io, std.testing.failing_allocator, invalid, config));
    invalid = id;
    invalid.generation = 0;
    try expectError(error.InvalidIdentity, inbox.init(io, std.testing.failing_allocator, invalid, config));
    for ([_]incoming.Config{ .{ .frame_bytes = 1 }, .{ .frame_bytes = framing.max_frame_bytes + 1 }, .{ .frame_bytes = 5, .payload_bytes = 4 } }) |bad| {
        try expectError(error.InvalidBudget, inbox.init(io, std.testing.failing_allocator, id, bad));
    }
    try inbox.init(io, std.testing.failing_allocator, id, config);
    defer cleanup(&inbox);
    try expectError(error.AlreadyInitialized, inbox.init(io, allocator, id, config));
    try equal(null, try inbox.receive());
    try expectError(error.NotStopped, inbox.discard(1));
}

test "callback snapshots and owner leases keep byte credits until release" {
    var inbox: Inbox(2) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    var scratch = [_]u8{ 0, 13, 42 };
    try inbox.post(id, .reliable, &scratch);
    @memset(&scratch, 255);
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    try equal(id, lease.session);
    try equal(framing.Channel.reliable, lease.channel);
    try std.testing.expectEqualSlices(u8, &.{ 0, 13, 42 }, lease.bytes());
    try equal(@as(usize, 1), (try inbox.status()).outstanding);
    try equal(@as(usize, 3), (try inbox.status()).payload_bytes);
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    const complete = (try lease.accept(&session, 1)).?;
    lease.deinit();
    lease.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 13, 42 }, complete);
    try equal(@as(usize, 0), lease.bytes().len);
    try equal(@as(usize, 0), (try inbox.status()).outstanding);
    try expectError(error.RetiredLease, lease.accept(&session, 2));
}

test "leased frames count against capacity and overflow cannot lose stop notification" {
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var inbox: Inbox(1) = .{};
    try inbox.init(io, failing.allocator(), id, config);
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 0, 1 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    try expectError(error.QueueFull, inbox.post(id, .unreliable, &.{ 0, 2 }));
    try equal(@as(usize, 1), failing.alloc_index);
    try equal(incoming.StopReason.queue_full, (try inbox.status()).reason.?);
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    try expectError(error.Closed, lease.accept(&session, 1));
    try equal(Session.CloseReason.inbound_overflow, session.close_reason.?);
    try expectError(error.Closed, inbox.receive());
    try equal(@as(usize, 1), (try inbox.status()).outstanding);
}

test "payload admission includes leased bytes and accepts the exact shared boundary" {
    var inbox: Inbox(4) = .{};
    try inbox.init(io, allocator, id, .{ .frame_bytes = 5, .payload_bytes = 8 });
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 0, 1, 2, 3, 4 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    try inbox.post(id, .unreliable, &.{ 0, 5, 6 });
    try equal(@as(usize, 8), (try inbox.status()).payload_bytes);
    try expectError(error.PayloadBudgetExceeded, inbox.post(id, .unreliable, &.{ 0, 7 }));
    try equal(incoming.StopReason.byte_budget, (try inbox.status()).reason.?);
    try equal(@as(usize, 1), try inbox.discard(1));
    try equal(@as(usize, 5), (try inbox.status()).payload_bytes);
}

test "malformed callback lengths fail closed before allocation" {
    const bytes = [_]u8{ 0, 1, 2, 3, 4, 5 };
    for ([_]usize{ 0, 1, 6 }) |length| {
        var inbox: Inbox(1) = .{};
        try inbox.init(io, std.testing.failing_allocator, id, config);
        defer cleanup(&inbox);
        try expectError(error.InvalidFrame, inbox.post(id, .reliable, bytes[0..length]));
        try equal(incoming.StopReason.invalid_frame, (try inbox.status()).reason.?);
        try equal(@as(usize, 0), (try inbox.status()).outstanding);
        var fixture: Fixture = .{};
        var session = try fixture.session(true);
        try expect(try inbox.applyStop(&session));
        try equal(Session.CloseReason.framing_error, session.close_reason.?);
    }
}

test "stale producer and lease identities cannot stop or mutate another generation" {
    var inbox: Inbox(2) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    var other = id;
    other.generation += 1;
    try expectError(error.StaleSession, inbox.post(other, .reliable, ""));
    try expectError(error.StaleSession, inbox.stop(other, .transport_closed));
    try equal(null, (try inbox.status()).reason);
    try inbox.post(id, .reliable, &.{ 0, 42 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    session.id = other;
    try expectError(error.StaleSession, lease.accept(&session, 1));
    try expectError(error.StaleSession, inbox.applyStop(&session));
    try equal(@as(u64, 0), session.last_ns);
    try equal(Session.State.open, session.state);
    try expect(std.mem.allEqual(u8, &fixture.reliable, 0));
    session.id = id;
    try std.testing.expectEqualSlices(u8, &.{42}, (try lease.accept(&session, 1)).?);
}

test "negotiating owner retains a frame lease until both channels open" {
    var inbox: Inbox(2) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 0, 42 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    var fixture: Fixture = .{};
    var session = try fixture.session(false);
    try expectError(error.NotOpen, lease.accept(&session, 1));
    try equal(@as(usize, 1), (try inbox.status()).outstanding);
    try session.channelOpened(id, .reliable, .required(.reliable), 1);
    try session.channelOpened(id, .unreliable, .required(.unreliable), 1);
    try std.testing.expectEqualSlices(u8, &.{42}, (try lease.accept(&session, 2)).?);
    try expectError(error.AlreadyAccepted, lease.accept(&session, 3));
}

test "a successful partial frame lease cannot be applied twice" {
    var inbox: Inbox(2) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 1, 42 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    try equal(null, try lease.accept(&session, 1));
    try expectError(error.AlreadyAccepted, lease.accept(&session, 2));
    try equal(@as(usize, 1), session.receivers[0].used);
    try equal(@as(u64, 1), session.last_ns);
    try equal(Session.State.open, session.state);
}

test "stop is sticky and bounded discard does not release a live lease" {
    var inbox: Inbox(4) = .{};
    try inbox.init(io, allocator, id, config);
    defer cleanup(&inbox);
    for (0..4) |_| try inbox.post(id, .reliable, &.{ 0, 1 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    try inbox.stop(id, .transport_closed);
    try inbox.stop(id, .requested);
    try expectError(error.Closed, inbox.post(id, .reliable, &.{ 0, 2 }));
    try equal(incoming.StopReason.transport_closed, (try inbox.status()).reason.?);
    try equal(@as(usize, 0), try inbox.discard(0));
    try equal(@as(usize, 2), try inbox.discard(2));
    try equal(@as(usize, 2), (try inbox.status()).outstanding);
    try equal(@as(usize, 1), try inbox.discard(2));
    try equal(@as(usize, 1), (try inbox.status()).outstanding);
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    try session.close(id, .outbound_failure);
    try expect(try inbox.applyStop(&session));
    try equal(Session.CloseReason.outbound_failure, session.close_reason.?);
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var inbox: Inbox(3) = .{};
    try inbox.init(io, gpa, id, config);
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 0, 1 });
    var lease = (try inbox.receive()).?;
    defer lease.deinit();
    try inbox.post(id, .unreliable, &.{ 0, 2 });
}

test "allocation failures retire reservations and preserve queued ownership" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
    var inbox: Inbox(1) = .{};
    try inbox.init(io, std.testing.failing_allocator, id, config);
    defer cleanup(&inbox);
    try expectError(error.OutOfMemory, inbox.post(id, .reliable, &.{ 0, 1 }));
    try equal(incoming.Status{ .reason = .out_of_memory, .outstanding = 0, .payload_bytes = 0 }, try inbox.status());
    var fixture: Fixture = .{};
    var session = try fixture.session(true);
    try expect(try inbox.applyStop(&session));
    try equal(Session.CloseReason.inbound_failure, session.close_reason.?);
}

fn deadline(start: std.Io.Timestamp) !void {
    if (start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.InboxTestTimeout;
}

const Producer = struct {
    inbox: *Inbox(64),
    channel: framing.Channel,
    result: ?anyerror = null,

    fn run(self: *Producer) void {
        for (0..32) |sequence| {
            var scratch = [_]u8{ 0, @backingInt(self.channel), @intCast(sequence) };
            self.inbox.post(id, self.channel, &scratch) catch |err| {
                self.result = err;
                return;
            };
            @memset(&scratch, 255);
        }
    }
};

test "concurrent channel callbacks publish independent snapshots in channel order" {
    var inbox: Inbox(64) = .{};
    try inbox.init(io, allocator, id, .{ .frame_bytes = 5, .payload_bytes = 192 });
    defer cleanup(&inbox);
    var producers = [_]Producer{ .{ .inbox = &inbox, .channel = .reliable }, .{ .inbox = &inbox, .channel = .unreliable } };
    const first = try std.Thread.spawn(.{}, Producer.run, .{&producers[0]});
    const second = std.Thread.spawn(.{}, Producer.run, .{&producers[1]}) catch |err| {
        first.join();
        return err;
    };
    first.join();
    second.join();
    for (producers) |producer| try equal(null, producer.result);
    try equal(@as(usize, 64), (try inbox.status()).outstanding);
    try equal(@as(usize, 192), (try inbox.status()).payload_bytes);
    var expected: [2]u8 = .{ 0, 0 };
    for (0..64) |_| {
        var lease = (try inbox.receive()).?;
        defer lease.deinit();
        const channel = @backingInt(lease.channel);
        try std.testing.expectEqualSlices(u8, &.{ 0, channel, expected[channel] }, lease.bytes());
        expected[channel] += 1;
    }
    try equal([2]u8{ 32, 32 }, expected);
    try equal(@as(usize, 0), (try inbox.status()).outstanding);
}

const HeldAllocator = struct {
    hold_free: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    allocations: std.atomic.Value(usize) = .init(0),
    frees: std.atomic.Value(usize) = .init(0),

    fn get(self: *HeldAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *HeldAllocator = @ptrCast(@alignCast(raw));
        _ = self.allocations.fetchAdd(1, .monotonic);
        if (!self.hold_free and !self.wait()) return null;
        return allocator.rawAlloc(length, alignment, address);
    }

    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *HeldAllocator = @ptrCast(@alignCast(raw));
        if (self.hold_free) _ = self.wait();
        allocator.rawFree(bytes, alignment, address);
        _ = self.frees.fetchAdd(1, .monotonic);
    }

    fn wait(self: *HeldAllocator) bool {
        self.entered.store(true, .release);
        const start = std.Io.Clock.awake.now(io);
        while (!self.proceed.load(.acquire)) {
            deadline(start) catch {
                self.timed_out.store(true, .release);
                return false;
            };
            std.Thread.yield() catch return false;
        }
        return true;
    }
};

fn reservationRace(comptime capacity: usize, settings: incoming.Config, expected: anyerror) !void {
    const Worker = struct {
        inbox: *Inbox(capacity),
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            self.inbox.post(id, .reliable, &.{ 0, 1, 2, 3, 4 }) catch |err| {
                self.result = err;
            };
        }
    };
    var held: HeldAllocator = .{};
    var inbox: Inbox(capacity) = .{};
    try inbox.init(io, held.get(), id, settings);
    defer cleanup(&inbox);
    var worker: Worker = .{ .inbox = &inbox };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    {
        defer {
            held.proceed.store(true, .release);
            thread.join();
        }
        const start = std.Io.Clock.awake.now(io);
        while (!held.entered.load(.acquire)) {
            try deadline(start);
            try std.Thread.yield();
        }
        try equal(@as(usize, 1), (try inbox.status()).outstanding);
        try equal(@as(usize, 5), (try inbox.status()).payload_bytes);
        try equal(null, try inbox.receive());
        try expectError(expected, inbox.post(id, .unreliable, &.{ 0, 2 }));
        try equal(@as(usize, 1), held.allocations.load(.acquire));
        try inbox.stop(id, .requested);
        try equal(@as(usize, 0), try inbox.discard(1));
        try equal(@as(usize, 1), (try inbox.status()).outstanding);
    }
    try equal(error.Closed, worker.result.?);
    try equal(@as(usize, 0), (try inbox.status()).outstanding);
    try equal(@as(usize, 0), (try inbox.status()).payload_bytes);
    try equal(@as(usize, 1), held.frees.load(.acquire));
    try expect(!held.timed_out.load(.acquire));
}

test "in-flight callback allocation holds count credit and stop does not wait for it" {
    try reservationRace(1, config, error.QueueFull);
}

test "in-flight callback allocation holds byte credit before the snapshot exists" {
    try reservationRace(2, .{ .frame_bytes = 5, .payload_bytes = 5 }, error.PayloadBudgetExceeded);
}

test "byte credits remain reserved until allocator free actually returns" {
    const Releaser = struct {
        lease: Inbox(2).Lease,
        fn run(self: *@This()) void {
            self.lease.deinit();
        }
    };
    var held: HeldAllocator = .{ .hold_free = true };
    var inbox: Inbox(2) = .{};
    try inbox.init(io, held.get(), id, .{ .frame_bytes = 5, .payload_bytes = 5 });
    defer cleanup(&inbox);
    try inbox.post(id, .reliable, &.{ 0, 1, 2 });
    var worker: Releaser = .{ .lease = (try inbox.receive()).? };
    const thread = std.Thread.spawn(.{}, Releaser.run, .{&worker}) catch |err| {
        held.proceed.store(true, .release);
        worker.lease.deinit();
        return err;
    };
    {
        defer {
            held.proceed.store(true, .release);
            thread.join();
        }
        const start = std.Io.Clock.awake.now(io);
        while (!held.entered.load(.acquire)) {
            try deadline(start);
            try std.Thread.yield();
        }
        try equal(@as(usize, 3), (try inbox.status()).payload_bytes);
        try equal(@as(usize, 0), held.frees.load(.acquire));
        try expectError(error.PayloadBudgetExceeded, inbox.post(id, .unreliable, &.{ 0, 3, 4 }));
        try equal(@as(usize, 1), held.allocations.load(.acquire));
    }
    try equal(@as(usize, 0), (try inbox.status()).payload_bytes);
    try equal(@as(usize, 1), held.frees.load(.acquire));
    try expect(!held.timed_out.load(.acquire));
}
