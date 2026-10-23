const std = @import("std");
const registry = @import("Manager.zig");
const connection = @import("Connection.zig");
const Session = @import("Session.zig");
const FrameSink = @import("FrameSink.zig");
const framing = @import("framing.zig");
const allocator = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const Manager = registry.Manager(8, 128, 4);
const config: connection.Config = .{
    .receive = .{ .frame_bytes = 5, .message_bytes = 32 },
    .incoming_bytes = 512,
    .outgoing = .{ .limits = .{ .{ .frame_bytes = 5, .message_bytes = 32 }, .{ .frame_bytes = 5, .message_bytes = 32 } }, .payload_bytes = 64, .buffered_bytes = 128 },
};
const budget: registry.Budget = .{
    .connection_visits = 4,
    .finalizer_results = 4,
    .events = 1024,
    .event_visits = 4096,
    .connection = .{ .send = .{ .steps = 32, .wire_bytes = 128 }, .receive_frames = 128, .receive_bytes = 512, .discard_frames = 128 },
};

fn deadline(start: std.Io.Timestamp) !void {
    if (start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.ManagerTestTimeout;
}

const Driver = struct {
    id: Session.Id = undefined,
    buffered: [2]u64 = .{ 0, 0 },
    sends: usize = 0,
    queries: usize = 0,
    finalize_calls: std.atomic.Value(usize) = .init(0),
    proceed: std.atomic.Value(bool) = .init(true),
    entered: std.atomic.Value(bool) = .init(false),
    failures: usize = 0,

    fn provider(self: *Driver) connection.Provider {
        return .{ .sink = .{ .session_id = self.id, .context = self, .buffered = amount, .send = send }, .finalizer = .{ .session = self.id, .context = self, .finalize = finalize } };
    }

    fn amount(raw: *anyopaque, channel: framing.Channel) FrameSink.Error!u64 {
        const self: *Driver = @ptrCast(@alignCast(raw));
        self.queries += 1;
        return self.buffered[@backingInt(channel)];
    }

    fn send(raw: *anyopaque, channel: framing.Channel, frame: []const u8) FrameSink.Error!FrameSink.Admission {
        const self: *Driver = @ptrCast(@alignCast(raw));
        self.sends += 1;
        self.buffered[@backingInt(channel)] += frame.len;
        return .accepted;
    }

    fn finalize(raw: *anyopaque) error{Failed}!void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        _ = self.finalize_calls.fetchAdd(1, .acq_rel);
        self.entered.store(true, .release);
        const start = std.Io.Clock.awake.now(io);
        while (!self.proceed.load(.acquire)) {
            deadline(start) catch return error.Failed;
            std.Thread.yield() catch return error.Failed;
        }
        if (self.failures != 0) {
            self.failures -= 1;
            return error.Failed;
        }
    }
};

const Fixture = struct {
    manager: Manager = .{},
    drivers: [4]Driver = @splat(.{}),
    epoch: u64 = 0,

    fn init(self: *Fixture, gpa: std.mem.Allocator, limits: registry.Limits) !void {
        try self.manager.init(gpa, io, 73, limits);
    }

    fn open(self: *Fixture) !Session.Id {
        const id = try self.manager.admit(config, self.manager.last_ns);
        const driver = &self.drivers[id.index];
        driver.id = id;
        var provider: ?connection.Provider = driver.provider();
        try self.manager.attach(id, &provider);
        try self.manager.channelOpened(id, .reliable, .required(.reliable), self.manager.last_ns);
        try self.manager.channelOpened(id, .unreliable, .required(.unreliable), self.manager.last_ns);
        return id;
    }

    fn tick(self: *Fixture, now: u64, work: registry.Budget) !void {
        self.epoch += 1;
        var scratch: [5]u8 = undefined;
        try self.manager.beginTick(self.epoch, now, &scratch, work);
    }

    fn cleanup(self: *Fixture) void {
        for (&self.drivers) |*driver| driver.proceed.store(true, .release);
        self.manager.requestStop() catch unreachable;
        const start = std.Io.Clock.awake.now(io);
        while (self.manager.records.count != 0) {
            self.tick(self.manager.last_ns, budget) catch @panic("Manager cleanup tick failed");
            while (self.manager.nextEvent(false) catch unreachable) |event| switch (event) {
                .finalized => |done| self.manager.retire(done.session) catch unreachable,
                .cleanup_failed => |id| self.manager.retryFinalizer(id) catch unreachable,
                else => {},
            };
            deadline(start) catch @panic("Manager cleanup deadline");
            std.Thread.yield() catch unreachable;
        }
        self.manager.join() catch unreachable;
        self.manager.deinit() catch unreachable;
    }
};

test "manager bounds admission before provider creation and retains credits until retirement" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 4, .payload_bytes = 612 });
    defer fixture.cleanup();
    try equal(@as(usize, 612), try Manager.reservationBytes(config));
    const id = try fixture.manager.admit(config, 0);
    const node = try fixture.manager.get(id);
    try equal(@as(usize, 32), node.session.receivers[0].storage.len);
    try equal(@as(usize, 4), node.session.receivers[1].storage.len);
    try equal(@as(usize, 612), fixture.manager.reserved_bytes);
    try expectError(error.PayloadBudgetExceeded, fixture.manager.admit(config, 0));
    try expectError(error.NotRetired, fixture.manager.retire(id));
    try fixture.manager.forceClose(id, .requested);
    try fixture.tick(0, budget);
    try equal(id, (try fixture.manager.nextEvent(false)).?.finalized.session);
    try expectError(error.PayloadBudgetExceeded, fixture.manager.admit(config, 0));
    try fixture.manager.retire(id);
    try equal(@as(usize, 0), fixture.manager.reserved_bytes);
    const reused = try fixture.manager.admit(config, 0);
    try equal(id.index, reused.index);
    try expect(reused.generation > id.generation);
    try expectError(error.StaleSession, fixture.manager.get(id));
}

test "registered opens support immediate rejection without consuming input" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const id = try fixture.open();
    try (try fixture.manager.get(id)).inbox.post(id, .reliable, &.{ 0, 42 });
    try expectError(error.TickRequired, fixture.manager.nextEvent(false));
    try fixture.tick(0, budget);
    try equal(id, (try fixture.manager.nextEvent(false)).?.opened);
    try equal(@as(usize, 1), (try (try fixture.manager.get(id)).inbox.status()).outstanding);
    try fixture.manager.forceClose(id, .requested);
    try equal(id, (try fixture.manager.nextEvent(false)).?.closed.session);
    try equal(@as(usize, 0), fixture.manager.stats.frames_read);
}

test "input backpressure preserves frames while receipts and closure still flow" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const first = try fixture.open();
    const second = try fixture.open();
    try fixture.tick(0, budget);
    for (0..2) |_| _ = (try fixture.manager.nextEvent(false)).?.opened;
    try (try fixture.manager.get(first)).inbox.post(first, .reliable, &.{ 0, 42 });
    _ = try fixture.manager.sendCopy(second, .reliable, "x");
    try fixture.tick(1, budget);
    fixture.drivers[second.index].buffered[0] = 0;
    try fixture.manager.disconnect(second);
    try fixture.tick(2, budget);
    try equal(second, (try fixture.manager.nextEvent(false)).?.sent.ticket.session);
    try equal(second, (try fixture.manager.nextEvent(false)).?.closed.session);
    try equal(@as(usize, 1), (try (try fixture.manager.get(first)).inbox.status()).outstanding);
    const packet = (try fixture.manager.nextEvent(true)).?.message;
    try equal(first, packet.session);
    try std.testing.expectEqualSlices(u8, &.{42}, packet.payload);
}

test "round robin visits and per-tick event quota survive busy sessions" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const first = try fixture.open();
    const second = try fixture.open();
    try fixture.tick(0, budget);
    for (0..2) |_| _ = (try fixture.manager.nextEvent(false)).?.opened;
    for (0..3) |value| try (try fixture.manager.get(first)).inbox.post(first, .reliable, &.{ 0, @intCast(value) });
    try (try fixture.manager.get(second)).inbox.post(second, .reliable, &.{ 0, 99 });
    var one = budget;
    one.connection_visits = 1;
    one.events = 1;
    one.event_visits = 2;
    try fixture.tick(1, one);
    try equal(first, (try fixture.manager.nextEvent(true)).?.message.session);
    try equal(null, try fixture.manager.nextEvent(true));
    try equal(@as(usize, 1), fixture.manager.stats.connections_updated);
    try fixture.tick(2, one);
    try equal(second, (try fixture.manager.nextEvent(true)).?.message.session);
    try equal(null, try fixture.manager.nextEvent(true));
    try equal(@as(usize, 2), (try (try fixture.manager.get(first)).inbox.status()).outstanding);
}

test "generation retirement rejects stale callbacks and exhausts rather than reuses identities" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 1, .payload_bytes = 612 });
    defer fixture.cleanup();
    const first = try fixture.manager.admit(config, 0);
    try expectError(error.PoolFull, fixture.manager.admit(config, 0));
    try fixture.manager.forceClose(first, .requested);
    try fixture.tick(0, budget);
    _ = (try fixture.manager.nextEvent(false)).?.finalized;
    try fixture.manager.retire(first);
    fixture.manager.records.slots[0].generation = std.math.maxInt(u64);
    const last = try fixture.manager.admit(config, 0);
    try expectError(error.StaleSession, fixture.manager.forceClose(first, .requested));
    try fixture.manager.forceClose(last, .requested);
    try fixture.tick(1, budget);
    _ = (try fixture.manager.nextEvent(false)).?.finalized;
    try fixture.manager.retire(last);
    try expectError(error.PoolFull, fixture.manager.admit(config, 1));
    try expectError(error.StaleSession, fixture.manager.retire(last));
}

test "manager shutdown retains stuck native contexts and still ticks other connections" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const first = try fixture.open();
    const second = try fixture.open();
    fixture.drivers[first.index].proceed.store(false, .release);
    try fixture.tick(0, budget);
    for (0..2) |_| _ = (try fixture.manager.nextEvent(false)).?.opened;
    try fixture.manager.forceClose(first, .requested);
    const start = std.Io.Clock.awake.now(io);
    while (!fixture.drivers[first.index].entered.load(.acquire)) {
        try deadline(start);
        try std.Thread.yield();
    }
    try (try fixture.manager.get(second)).inbox.post(second, .reliable, &.{ 0, 42 });
    try fixture.tick(1, budget);
    try equal(first, (try fixture.manager.nextEvent(true)).?.closed.session);
    try equal(second, (try fixture.manager.nextEvent(true)).?.message.session);
    try equal(@as(usize, 1224), fixture.manager.reserved_bytes);
    try fixture.manager.requestStop();
    try expectError(error.Stopping, fixture.manager.admit(config, 1));
    try expectError(error.WorkOutstanding, fixture.manager.join());
    try expect(!try fixture.manager.tryJoin());
    try expectError(error.NotJoined, fixture.manager.deinit());
}

test "cleanup failure routes to its session without returning count or payload credits" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 1, .payload_bytes = 612 });
    defer fixture.cleanup();
    const id = try fixture.open();
    fixture.drivers[id.index].failures = 1;
    try fixture.tick(0, budget);
    _ = (try fixture.manager.nextEvent(false)).?.opened;
    try fixture.manager.forceClose(id, .requested);
    const start = std.Io.Clock.awake.now(io);
    while (!(try fixture.manager.get(id)).failure_pending) {
        _ = try fixture.manager.collectFinalizers(1);
        try deadline(start);
        try std.Thread.yield();
    }
    try equal(id, (try fixture.manager.nextEvent(false)).?.closed.session);
    try equal(id, (try fixture.manager.nextEvent(false)).?.cleanup_failed);
    try equal(@as(usize, 612), fixture.manager.reserved_bytes);
    try expectError(error.NotRetired, fixture.manager.retire(id));
    try fixture.manager.retryFinalizer(id);
}

test "manager rejects invalid limits and reservation overflow before allocation" {
    var uninitialized: Manager = .{};
    try expectError(error.NotInitialized, uninitialized.get(.{ .owner = 1, .index = 0, .generation = 1 }));
    try expectError(error.InvalidLimits, uninitialized.init(allocator, io, 1, .{ .connections = 0, .payload_bytes = 1 }));
    try expectError(error.InvalidLimits, uninitialized.init(allocator, io, 1, .{ .connections = 5, .payload_bytes = 1 }));
    try expectError(error.InvalidOwner, uninitialized.init(allocator, io, 0, .{ .connections = 1, .payload_bytes = 1 }));
    var invalid = config;
    invalid.receive.frame_bytes = 1;
    try expectError(error.InvalidLimits, Manager.reservationBytes(invalid));
    invalid = config;
    invalid.incoming_bytes = std.math.maxInt(usize);
    try expectError(error.PayloadBudgetExceeded, Manager.reservationBytes(invalid));
    invalid = config;
    invalid.outgoing.payload_bytes = std.math.maxInt(usize);
    try expectError(error.PayloadBudgetExceeded, Manager.reservationBytes(invalid));
}

test "scratch alias across connections and reaper records rejects before any sender work" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const first = try fixture.open();
    const second = try fixture.open();
    _ = try fixture.manager.sendCopy(first, .reliable, "x");
    var one = budget;
    one.connection_visits = 1;
    const other_storage = (try fixture.manager.get(second)).session.receivers[0].storage;
    try expectError(error.AliasedScratch, fixture.manager.beginTick(1, 0, other_storage, one));
    const records = std.mem.sliceAsBytes(fixture.manager.reaper.records.slots);
    try expectError(error.AliasedScratch, fixture.manager.beginTick(1, 0, records, one));
    var scratch: [4]u8 = undefined;
    try expectError(error.NoSpace, fixture.manager.beginTick(1, 0, &scratch, one));
    try equal(@as(?u64, null), fixture.manager.last_tick);
    try equal(@as(usize, 0), fixture.drivers[first.index].queries);
    try equal(@as(usize, 0), fixture.drivers[first.index].sends);
    try equal(@as(usize, 1), (try fixture.manager.get(first)).outbox.outstanding);
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(gpa, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const id = try fixture.open();
    _ = try fixture.manager.sendCopy(id, .reliable, "x");
    try (try fixture.manager.get(id)).inbox.post(id, .reliable, &.{ 0, 42 });
    try fixture.tick(0, budget);
    _ = try fixture.manager.nextEvent(true);
}

test "manager allocation failures release admission, snapshots, worker and pool" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}

test "payload and configuration admission precede allocation attempts" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 612 });
    defer fixture.cleanup();
    _ = try fixture.manager.admit(config, 0);
    fixture.manager.allocator = std.testing.failing_allocator;
    defer fixture.manager.allocator = allocator;
    try expectError(error.PayloadBudgetExceeded, fixture.manager.admit(config, 0));
    var invalid = config;
    invalid.incoming_bytes = 0;
    try expectError(error.InvalidBudget, fixture.manager.admit(invalid, 0));
    try equal(@as(u32, 1), fixture.manager.records.count);
    try equal(@as(usize, 612), fixture.manager.reserved_bytes);
}

test "one-slot event visits count empty slots and preserve pending application data" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 4, .payload_bytes = 612 });
    defer fixture.cleanup();
    const id = try fixture.open();
    try (try fixture.manager.get(id)).inbox.post(id, .reliable, &.{ 0, 42 });
    var one = budget;
    one.events = 10;
    one.event_visits = 1;
    try fixture.tick(0, one);
    try equal(id, (try fixture.manager.nextEvent(false)).?.opened);
    try equal(null, try fixture.manager.nextEvent(true));
    for (1..4) |now| {
        try fixture.tick(now, one);
        try equal(null, try fixture.manager.nextEvent(true));
        try equal(@as(usize, 1), fixture.manager.stats.event_visits);
    }
    try equal(@as(usize, 1), (try (try fixture.manager.get(id)).inbox.status()).outstanding);
    try fixture.tick(4, one);
    try equal(id, (try fixture.manager.nextEvent(true)).?.message.session);
}

test "repeated manager pulls cannot reset the 64-packet connection quota" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 1, .payload_bytes = 612 });
    defer fixture.cleanup();
    const id = try fixture.open();
    try fixture.tick(0, budget);
    _ = (try fixture.manager.nextEvent(false)).?.opened;
    for (0..65) |sequence| try (try fixture.manager.get(id)).inbox.post(id, .reliable, &.{ 0, @intCast(sequence) });
    try fixture.tick(1, budget);
    for (0..64) |_| try equal(id, (try fixture.manager.nextEvent(true)).?.message.session);
    try equal(null, try fixture.manager.nextEvent(true));
    try equal(@as(usize, 64), fixture.manager.stats.packets);
    try fixture.tick(2, budget);
    try std.testing.expectEqualSlices(u8, &.{64}, (try fixture.manager.nextEvent(true)).?.message.payload);
}

test "stale scope and time reject before clocks, cursors or provider observations change" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 1, .payload_bytes = 612 });
    defer fixture.cleanup();
    const id = try fixture.open();
    try fixture.tick(5, budget);
    var foreign = id;
    foreign.owner += 1;
    try expectError(error.StaleSession, fixture.manager.channelOpened(foreign, .reliable, .required(.reliable), 99));
    try expectError(error.StaleSession, fixture.manager.forceClose(foreign, .requested));
    var scratch: [5]u8 = undefined;
    try expectError(error.ClockWentBackwards, fixture.manager.beginTick(2, 4, &scratch, budget));
    try expectError(error.StaleTick, fixture.manager.beginTick(1, 5, &scratch, budget));
    try equal(@as(u64, 5), fixture.manager.last_ns);
    try equal(@as(?u64, 1), fixture.manager.last_tick);
    try equal(@as(usize, 2), fixture.drivers[id.index].queries);
}

test "owned transfers cannot claim another receiver or reaper metadata" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 2, .payload_bytes = 1224 });
    defer fixture.cleanup();
    const first = try fixture.open();
    const second = try fixture.open();
    const bytes = (try fixture.manager.get(second)).session.receivers[0].storage;
    var pending: ?@import("../foundation/OwnedBytes.zig") = .{ .storage = bytes };
    try expectError(error.AliasedPayload, fixture.manager.sendOwned(first, .reliable, &pending));
    try expect(pending != null);
    const metadata = std.mem.sliceAsBytes(fixture.manager.reaper.records.slots);
    const descriptor: *@TypeOf(pending) = @ptrCast(@alignCast(metadata.ptr));
    try expectError(error.AliasedPayload, fixture.manager.sendOwned(first, .reliable, descriptor));
    const provider: *?connection.Provider = @ptrCast(@alignCast(metadata.ptr));
    try expectError(error.AliasedProvider, fixture.manager.attach(first, provider));
    try equal(@as(usize, 0), (try fixture.manager.get(first)).outbox.outstanding);
}

test "late channel opens do not advance a closed connection clock" {
    var fixture: Fixture = .{};
    try fixture.init(allocator, .{ .connections = 1, .payload_bytes = 612 });
    defer fixture.cleanup();
    const id = try fixture.open();
    try fixture.tick(5, budget);
    try fixture.manager.forceClose(id, .requested);
    try expectError(error.NotNegotiating, fixture.manager.channelOpened(id, .reliable, .required(.reliable), 99));
    try equal(@as(u64, 5), fixture.manager.last_ns);
    try fixture.tick(6, budget);
}
