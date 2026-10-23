const std = @import("std");
const owner = @import("Connection.zig");
const teardown = @import("Reaper.zig");
const FrameSink = @import("FrameSink.zig");
const Session = @import("Session.zig");
const framing = @import("framing.zig");
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const allocator = std.testing.allocator;
const io = std.testing.io;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const id: Session.Id = .{ .owner = 19, .index = 0, .generation = 1 };
const Node = owner.Connection(8, 128, 2);
const Reaper = teardown.Reaper(2);
const config: owner.Config = .{
    .receive = .{ .frame_bytes = 5, .message_bytes = 32 },
    .incoming_bytes = 512,
    .outgoing = .{ .limits = .{ .{ .frame_bytes = 5, .message_bytes = 32 }, .{ .frame_bytes = 5, .message_bytes = 32 } }, .payload_bytes = 64, .buffered_bytes = 128 },
};
const budget: owner.Budget = .{ .send = .{ .steps = 32, .wire_bytes = 128 }, .receive_frames = 128, .receive_bytes = 512, .discard_frames = 128 };

fn deadline(start: std.Io.Timestamp) !void {
    if (start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.ConnectionTestTimeout;
}

const Driver = struct {
    buffered: [2]u64 = .{ 0, 0 },
    closed: bool = false,
    blocked: bool = false,
    sends: usize = 0,
    queries: usize = 0,
    finalize_calls: std.atomic.Value(usize) = .init(0),
    proceed: std.atomic.Value(bool) = .init(true),
    finished: std.atomic.Value(bool) = .init(false),
    failures: usize = 0,

    fn provider(self: *Driver) owner.Provider {
        return .{ .sink = .{ .session_id = id, .context = self, .buffered = amount, .send = send }, .finalizer = .{ .session = id, .context = self, .finalize = finalize } };
    }

    fn amount(raw: *anyopaque, channel: framing.Channel) FrameSink.Error!u64 {
        const self: *Driver = @ptrCast(@alignCast(raw));
        self.queries += 1;
        return self.buffered[@backingInt(channel)];
    }

    fn send(raw: *anyopaque, channel: framing.Channel, frame: []const u8) FrameSink.Error!FrameSink.Admission {
        const self: *Driver = @ptrCast(@alignCast(raw));
        if (self.closed) return error.Closed;
        if (self.blocked) return .blocked;
        self.sends += 1;
        self.buffered[@backingInt(channel)] += frame.len;
        return .accepted;
    }

    fn finalize(raw: *anyopaque) error{Failed}!void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        _ = self.finalize_calls.fetchAdd(1, .acq_rel);
        const start = std.Io.Clock.awake.now(io);
        while (!self.proceed.load(.acquire)) {
            deadline(start) catch return error.Failed;
            std.Thread.yield() catch return error.Failed;
        }
        if (self.failures != 0) {
            self.failures -= 1;
            return error.Failed;
        }
        self.finished.store(true, .release);
    }
};

const Fixture = struct {
    reaper: Reaper = .{},
    node: Node = .{},
    driver: Driver = .{},
    reliable: [32]u8 = @splat(0),
    unreliable: [4]u8 = @splat(0),
    epoch: u64 = 0,

    fn init(self: *Fixture, gpa: std.mem.Allocator, attach: bool, open: bool) !void {
        try self.reaper.init(gpa, io, 31);
        errdefer {
            self.reaper.requestStop() catch unreachable;
            self.reaper.join() catch unreachable;
            self.reaper.deinit() catch unreachable;
        }
        try self.node.init(gpa, io, &self.reaper, id, &self.reliable, &self.unreliable, config, 0);
        if (attach) {
            var pending: ?owner.Provider = self.driver.provider();
            try self.node.attach(id, &pending);
        }
        if (open) {
            try self.node.channelOpened(id, .reliable, .required(.reliable), 0);
            try self.node.channelOpened(id, .unreliable, .required(.unreliable), 0);
            const event = (try self.node.nextEvent(id)).?;
            try equal(id, event.opened);
        }
    }

    fn tick(self: *Fixture, now: u64, work: owner.Budget) !void {
        self.epoch += 1;
        var scratch: [5]u8 = undefined;
        try self.node.beginTick(id, self.epoch, now, &scratch, work);
    }

    fn collect(self: *Fixture) !void {
        if (try self.reaper.collect()) |completion| try self.node.finalized(completion);
    }

    fn cleanup(self: *Fixture) void {
        self.driver.proceed.store(true, .release);
        self.node.forceClose(id, .requested) catch unreachable;
        const start = std.Io.Clock.awake.now(io);
        while (self.node.phase != .retired) {
            self.collect() catch @panic("Connection test cleanup result failed");
            _ = self.node.discardClosed(id, 128) catch unreachable;
            while (self.node.nextEvent(id) catch unreachable) |event| switch (event) {
                .cleanup_failed => self.node.retryFinalizer(id) catch unreachable,
                else => {},
            };
            deadline(start) catch @panic("Connection test cleanup timed out");
            std.Thread.yield() catch unreachable;
        }
        self.node.deinit() catch unreachable;
        self.reaper.requestStop() catch unreachable;
        self.reaper.join() catch unreachable;
        self.reaper.deinit() catch unreachable;
    }
};

test "unattached connection cancellation returns its reservation without a native task" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, false, false);
    defer fixture.cleanup();
    try expectError(error.NotOpen, fixture.node.sendCopy(allocator, id, .reliable, "x"));
    try expectError(error.NotRetired, fixture.node.deinit());
    try fixture.node.forceClose(id, .requested);
    const event = (try fixture.node.nextEvent(id)).?;
    try equal(null, event.finalized.task);
    try equal(@as(u32, 0), fixture.reaper.records.count);
    try equal(@as(usize, 0), fixture.driver.finalize_calls.load(.acquire));
}

test "provider identity and one-time binding reject before moving ownership" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, false, false);
    defer fixture.cleanup();
    var pending: ?owner.Provider = fixture.driver.provider();
    pending.?.sink.session_id.generation += 1;
    try expectError(error.WrongProvider, fixture.node.attach(id, &pending));
    try expect(pending != null);
    pending = fixture.driver.provider();
    pending.?.finalizer.session.owner += 1;
    try expectError(error.WrongProvider, fixture.node.attach(id, &pending));
    pending = fixture.driver.provider();
    try fixture.node.attach(id, &pending);
    try equal(null, pending);
    pending = fixture.driver.provider();
    try expectError(error.NotReserved, fixture.node.attach(id, &pending));
    try expect(pending != null);
}

test "open notification precedes input and closing an unpublished connection emits no close" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, false);
    defer fixture.cleanup();
    try fixture.node.channelOpened(id, .reliable, .required(.reliable), 0);
    try equal(null, try fixture.node.nextEvent(id));
    try fixture.node.channelOpened(id, .unreliable, .required(.unreliable), 0);
    try fixture.node.inbox.post(id, .reliable, &.{ 0, 42 });
    try fixture.tick(1, budget);
    try equal(@as(usize, 1), (try fixture.node.inbox.status()).outstanding);
    try equal(id, (try fixture.node.nextEvent(id)).?.opened);
    const message = (try fixture.node.nextEvent(id)).?.message;
    try std.testing.expectEqualSlices(u8, &.{42}, message.payload);
    try equal(@as(usize, 0), (try fixture.node.inbox.status()).outstanding);

    var unpublished: Fixture = .{};
    try unpublished.init(allocator, true, false);
    defer unpublished.cleanup();
    try unpublished.node.channelOpened(id, .reliable, .required(.reliable), 0);
    try unpublished.node.channelOpened(id, .unreliable, .required(.unreliable), 0);
    try unpublished.node.forceClose(id, .requested);
    try expect((try unpublished.node.nextEvent(id)) == null);
}

test "reported final drain receipt is emitted before a pending native close" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    const ticket = try fixture.node.sendCopy(allocator, id, .reliable, "abcdef");
    try fixture.tick(1, budget);
    try equal(@as(usize, 2), fixture.driver.sends);
    try equal(@as(u64, 8), fixture.driver.buffered[0]);
    fixture.driver.buffered[0] = 0;
    fixture.driver.closed = true;
    try fixture.node.inbox.stop(id, .transport_closed);
    var zero_send = budget;
    zero_send.send = .{ .steps = 0, .wire_bytes = 0 };
    try fixture.tick(2, zero_send);
    const sent = (try fixture.node.nextEvent(id)).?.sent;
    try equal(ticket, sent.ticket);
    try equal(@import("Outbox.zig").Outcome.drained, sent.outcome);
    const closed = (try fixture.node.nextEvent(id)).?.closed;
    try equal(Session.CloseReason.transport_closed, closed.reason);
    try equal(@as(usize, 2), fixture.driver.sends);
}

test "graceful disconnect stops admission and drains before closing" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    _ = try fixture.node.sendCopy(allocator, id, .reliable, "abcdef");
    try fixture.tick(1, budget);
    try fixture.node.disconnect(id);
    var pending: ?OwnedBytes = try .copy(allocator, "kept", 4);
    defer if (pending) |*payload| payload.deinit();
    try expectError(error.Draining, fixture.node.sendOwned(id, .reliable, &pending));
    try expect(pending != null);
    try fixture.tick(100, budget);
    try equal(owner.Phase.draining, fixture.node.phase);
    fixture.driver.buffered[0] = 0;
    try fixture.tick(std.time.ns_per_s, budget);
    try equal(@import("Outbox.zig").Outcome.drained, (try fixture.node.nextEvent(id)).?.sent.outcome);
    const closed = (try fixture.node.nextEvent(id)).?.closed;
    try equal(Session.CloseReason.requested, closed.reason);
    try expect(!closed.flush_expired);
}

test "grace deadline begins on update and repeated requests cannot extend it" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    _ = try fixture.node.sendCopy(allocator, id, .reliable, "abcdef");
    try fixture.tick(0, budget);
    try fixture.node.disconnect(id);
    try fixture.tick(5 * std.time.ns_per_s, budget);
    try fixture.node.disconnect(id);
    try fixture.tick(7 * std.time.ns_per_s - 1, budget);
    try equal(owner.Phase.draining, fixture.node.phase);
    try fixture.tick(7 * std.time.ns_per_s, budget);
    try equal(@import("Outbox.zig").Outcome.cancelled, (try fixture.node.nextEvent(id)).?.sent.outcome);
    try expect((try fixture.node.nextEvent(id)).?.closed.flush_expired);
    try equal(@as(usize, 2), fixture.driver.sends);
}

test "empty-message receipts wait for control buffering and drain at the deadline" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    fixture.driver.buffered[0] = 100;
    _ = try fixture.node.sendCopy(allocator, id, .reliable, "");
    try fixture.tick(0, budget);
    try fixture.node.disconnect(id);
    try fixture.tick(0, budget);
    try equal(owner.Phase.draining, fixture.node.phase);
    fixture.driver.buffered[0] = 0;
    try fixture.tick(owner.flush_timeout_ns, budget);
    try equal(@import("Outbox.zig").Outcome.drained, (try fixture.node.nextEvent(id)).?.sent.outcome);
    try expect(!(try fixture.node.nextEvent(id)).?.closed.flush_expired);
    try equal(@as(usize, 0), fixture.driver.sends);
}

test "normal remote closure preserves graceful intent while transport failure overrides it" {
    for ([_]@import("Inbox.zig").StopReason{ .transport_closed, .transport_failed }) |reason| {
        var fixture: Fixture = .{};
        try fixture.init(allocator, true, true);
        defer fixture.cleanup();
        try fixture.node.disconnect(id);
        try fixture.node.inbox.stop(id, reason);
        try fixture.tick(1, budget);
        const closed = (try fixture.node.nextEvent(id)).?.closed;
        try equal(if (reason == .transport_closed) Session.CloseReason.requested else Session.CloseReason.transport_failure, closed.reason);
    }
}

test "input pull enforces 64 messages per increasing owner tick" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    for (0..65) |sequence| try fixture.node.inbox.post(id, .reliable, &.{ 0, @intCast(sequence) });
    try fixture.tick(0, budget);
    for (0..64) |sequence| {
        const event = (try fixture.node.nextEvent(id)).?.message;
        try std.testing.expectEqualSlices(u8, &.{@intCast(sequence)}, event.payload);
    }
    try equal(null, try fixture.node.nextEvent(id));
    try equal(@as(usize, 64), fixture.node.stats.packets);
    try equal(@as(usize, 1), (try fixture.node.inbox.status()).outstanding);
    try fixture.tick(1, budget);
    try std.testing.expectEqualSlices(u8, &.{64}, (try fixture.node.nextEvent(id)).?.message.payload);
}

test "small receive budgets retain a frame lease and forced closure releases it" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    try fixture.node.inbox.post(id, .reliable, &.{ 0, 42, 13 });
    var small = budget;
    small.receive_bytes = 2;
    try fixture.tick(0, small);
    try equal(null, try fixture.node.nextEvent(id));
    try expect(fixture.node.held != null);
    try equal(@as(usize, 3), (try fixture.node.inbox.status()).payload_bytes);
    try equal(@as(usize, 0), fixture.node.stats.frames);
    try fixture.tick(1, budget);
    try std.testing.expectEqualSlices(u8, &.{ 42, 13 }, (try fixture.node.nextEvent(id)).?.message.payload);
    try fixture.node.inbox.post(id, .reliable, &.{ 0, 42, 13 });
    try fixture.tick(2, small);
    try equal(null, try fixture.node.nextEvent(id));
    try fixture.node.forceClose(id, .requested);
    try equal(@as(usize, 0), (try fixture.node.inbox.status()).payload_bytes);
}

test "invalid frame and reported native overflow close the connection without dropping outcomes" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    try fixture.node.inbox.post(id, .unreliable, &.{ 1, 42 });
    try fixture.tick(1, budget);
    try equal(Session.CloseReason.framing_error, (try fixture.node.nextEvent(id)).?.closed.reason);

    var overflow: Fixture = .{};
    try overflow.init(allocator, true, true);
    defer overflow.cleanup();
    overflow.driver.buffered = .{ std.math.maxInt(u64), 1 };
    try overflow.tick(0, budget);
    try equal(Session.CloseReason.outbound_failure, (try overflow.node.nextEvent(id)).?.closed.reason);
}

test "stale identity, tick, clock and scratch reject before connection mutation" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    var old = id;
    old.generation += 1;
    var scratch: [5]u8 = undefined;
    try expectError(error.StaleSession, fixture.node.beginTick(old, 1, 0, &scratch, budget));
    try expectError(error.StaleSession, fixture.node.disconnect(old));
    try expectError(error.StaleSession, fixture.node.forceClose(old, .requested));
    try expectError(error.StaleSession, fixture.node.nextEvent(old));
    try fixture.node.beginTick(id, 1, 5, &scratch, budget);
    const queries = fixture.driver.queries;
    try expectError(error.StaleTick, fixture.node.beginTick(id, 1, 5, &scratch, budget));
    try expectError(error.ClockWentBackwards, fixture.node.beginTick(id, 2, 4, &scratch, budget));
    try expectError(error.AliasedScratch, fixture.node.beginTick(id, 2, 5, std.mem.asBytes(&fixture.node), budget));
    try equal(queries, fixture.driver.queries);
    try equal(@as(?u64, 1), fixture.node.last_tick);
}

test "cleanup failures stay observable and contexts return only after explicit retry" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    fixture.driver.failures = 1;
    try fixture.node.forceClose(id, .requested);
    const start = std.Io.Clock.awake.now(io);
    while (!fixture.node.failure_pending) {
        try fixture.collect();
        try deadline(start);
        try std.Thread.yield();
    }
    try expectError(error.UnreportedFailure, fixture.node.retryFinalizer(id));
    _ = (try fixture.node.nextEvent(id)).?.closed;
    try equal(id, (try fixture.node.nextEvent(id)).?.cleanup_failed);
    try expect(!fixture.driver.finished.load(.acquire));
    try fixture.node.retryFinalizer(id);
    while (!fixture.node.quiesced) {
        try fixture.collect();
        try deadline(start);
        try std.Thread.yield();
    }
    const done = (try fixture.node.nextEvent(id)).?.finalized;
    try equal(@as(*anyopaque, &fixture.driver), done.task.?.context);
    try equal(@as(usize, 2), fixture.driver.finalize_calls.load(.acquire));
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(gpa, true, true);
    defer fixture.cleanup();
    _ = try fixture.node.sendCopy(gpa, id, .reliable, "abc");
    try fixture.node.inbox.post(id, .unreliable, &.{ 0, 42 });
    try fixture.tick(0, budget);
    _ = try fixture.node.nextEvent(id);
}

test "native quiescence retains the connection until ingress and notifications retire" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, true);
    defer fixture.cleanup();
    _ = try fixture.node.sendCopy(allocator, id, .reliable, "pending");
    try fixture.node.inbox.post(id, .reliable, &.{ 0, 1 });
    try fixture.node.inbox.post(id, .reliable, &.{ 0, 2 });
    var lease = (try fixture.node.inbox.receive()).?;
    defer lease.deinit();
    try fixture.node.forceClose(id, .requested);
    const start = std.Io.Clock.awake.now(io);
    while (!fixture.node.quiesced) {
        try fixture.collect();
        try deadline(start);
        try std.Thread.yield();
    }
    try equal(@as(usize, 2), (try fixture.node.inbox.status()).outstanding);
    try equal(@import("Outbox.zig").Outcome.cancelled, (try fixture.node.nextEvent(id)).?.sent.outcome);
    try equal(Session.CloseReason.requested, (try fixture.node.nextEvent(id)).?.closed.reason);
    try equal(null, try fixture.node.nextEvent(id));
    try expectError(error.NotRetired, fixture.node.deinit());
    try equal(@as(usize, 1), try fixture.node.discardClosed(id, 1));
    try equal(null, try fixture.node.nextEvent(id));
    lease.deinit();
    const done = (try fixture.node.nextEvent(id)).?.finalized;
    try equal(@as(*anyopaque, &fixture.driver), done.task.?.context);
    try equal(owner.Phase.retired, fixture.node.phase);
}

test "connection allocation faults retain no queued snapshots or reaper reservations" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}

test "provider frame negotiation only lowers limits before application admission" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, false);
    defer fixture.cleanup();
    try equal(@as(usize, 4), try fixture.node.limitSendFrame(id, .reliable, 4));
    try equal(@as(usize, 4), try fixture.node.limitSendFrame(id, .reliable, 64));
    try expectError(error.InvalidLimits, fixture.node.limitSendFrame(id, .reliable, 1));
    var stale = id;
    stale.generation += 1;
    try expectError(error.StaleSession, fixture.node.limitSendFrame(stale, .unreliable, 2));
    try equal(@as(usize, 5), fixture.node.outbox.config.limits[1].frame_bytes);
    try fixture.node.channelOpened(id, .reliable, .required(.reliable), 0);
    try fixture.node.channelOpened(id, .unreliable, .required(.unreliable), 0);
    try expectError(error.NotNegotiating, fixture.node.limitSendFrame(id, .reliable, 2));
    try equal(@as(usize, 4), fixture.node.outbox.config.limits[0].frame_bytes);
}

test "graceful lifecycle and receipt ordering match the upstream public Session oracle" {
    const Oracle = struct {
        oracle: std.json.Value,
        packet_limit: usize,
        flush_timeout_ns: u64,
        cases: []const struct {
            name: []const u8,
            payload_hex: ?[]const u8,
            phases: []const struct {
                time_ns: u64,
                buffered: u64,
                transport: enum { CONNECTED, CLOSED, FAILED },
                acknowledged: []const u64,
                connected: bool,
                disconnected: bool,
                reason: []const u8,
            },
        },
    };
    const parsed = try std.json.parseFromSlice(Oracle, allocator, @embedFile("fixtures/lifecycle.json"), .{});
    defer parsed.deinit();
    try equal(parsed.value.packet_limit, owner.packet_limit);
    try equal(parsed.value.flush_timeout_ns, owner.flush_timeout_ns);
    for (parsed.value.cases) |case| {
        var fixture: Fixture = .{};
        try fixture.init(allocator, true, true);
        defer fixture.cleanup();
        if (case.payload_hex) |hex| {
            var bytes: [32]u8 = undefined;
            const payload = try std.fmt.hexToBytes(&bytes, hex);
            if (payload.len == 0) fixture.driver.buffered[0] = case.phases[0].buffered;
            _ = try fixture.node.sendCopy(allocator, id, .reliable, payload);
            try fixture.tick(0, budget);
        }
        try fixture.node.disconnect(id);
        for (case.phases) |phase| {
            fixture.driver.buffered[0] = phase.buffered;
            fixture.driver.closed = phase.transport != .CONNECTED;
            if (phase.transport != .CONNECTED) try fixture.node.inbox.stop(id, if (phase.transport == .FAILED) .transport_failed else .transport_closed);
            try fixture.node.disconnect(id);
            try fixture.tick(phase.time_ns, budget);
            var receipts: [8]u64 = undefined;
            var count: usize = 0;
            var saw_close = false;
            while (try fixture.node.nextEvent(id)) |event| switch (event) {
                .sent => |completion| if (completion.outcome == .drained) {
                    try expect(!saw_close);
                    receipts[count] = completion.ticket.sequence;
                    count += 1;
                },
                .closed => |closed| {
                    saw_close = true;
                    try equal(if (std.mem.eql(u8, phase.reason, "CONNECTION_FAILED")) Session.CloseReason.transport_failure else Session.CloseReason.requested, closed.reason);
                },
                else => return error.UnexpectedOracleEvent,
            };
            try std.testing.expectEqualSlices(u64, phase.acknowledged, receipts[0..count]);
            try equal(phase.connected, fixture.node.phase == .open);
            try equal(phase.disconnected, fixture.node.session.state == .closed);
        }
    }
}
