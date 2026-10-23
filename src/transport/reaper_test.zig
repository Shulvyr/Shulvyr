const std = @import("std");
const teardown = @import("Reaper.zig");
const Reaper = teardown.Reaper;
const Session = @import("Session.zig");
const allocator = std.testing.allocator;
const io = std.testing.io;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const session: Session.Id = .{ .owner = 11, .index = 3, .generation = 7 };

fn deadline(start: std.Io.Timestamp) !void {
    if (start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.ReaperTestTimeout;
}

const Context = struct {
    proceed: std.atomic.Value(bool) = .init(true),
    entered: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(bool) = .init(false),
    thread: std.atomic.Value(std.Thread.Id) = .init(0),
    failures: usize = 0,

    fn task(self: *Context, id: Session.Id) teardown.Task {
        return .{ .session = id, .context = self, .finalize = finalize };
    }

    fn finalize(raw: *anyopaque) error{Failed}!void {
        const self: *Context = @ptrCast(@alignCast(raw));
        self.thread.store(std.Thread.getCurrentId(), .release);
        _ = self.calls.fetchAdd(1, .acq_rel);
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
        self.completed.store(true, .release);
    }
};

fn next(reaper: anytype) !@TypeOf(reaper.*).Completion {
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        if (try reaper.collect()) |completion| return completion;
        try deadline(start);
        try std.Thread.yield();
    }
}

fn cleanup(reaper: anytype) void {
    reaper.requestStop() catch unreachable;
    for (reaper.records.slots, 0..) |slot, index| {
        if (slot.value) |record| {
            const ticket: @TypeOf(reaper.*).Ticket = .{ .owner = reaper.records.owner, .index = @intCast(index), .generation = slot.generation };
            switch (record.phase) {
                .reserved => reaper.cancelReservation(ticket) catch unreachable,
                .failed => reaper.retry(ticket) catch unreachable,
                .quiesced => _ = reaper.takeFinalized(ticket) catch unreachable,
                .submitted => {},
            }
        }
    }
    while (reaper.records.count != 0) {
        const completion = next(reaper) catch @panic("Test reaper failed to drain");
        if (completion.outcome == .quiesced) {
            _ = reaper.takeFinalized(completion.ticket) catch unreachable;
        } else reaper.retry(completion.ticket) catch unreachable;
    }
    reaper.join() catch unreachable;
    reaper.deinit() catch unreachable;
}

test "reaper rejects use before initialization and keeps failed init retryable" {
    var reaper: Reaper(1) = .{};
    var context: Context = .{};
    var pending: ?teardown.Task = context.task(session);
    const ticket: Reaper(1).Ticket = .{ .owner = 1, .index = 0, .generation = 1 };
    try expectError(error.NotInitialized, reaper.reserve(session));
    try expectError(error.NotInitialized, reaper.submit(ticket, &pending));
    try expectError(error.NotInitialized, reaper.collect());
    try expectError(error.NotInitialized, reaper.requestStop());
    try expectError(error.NotInitialized, reaper.tryJoin());
    try expectError(error.NotInitialized, reaper.join());
    try expectError(error.NotJoined, reaper.deinit());
    try expectError(error.InvalidOwner, reaper.init(allocator, io, 0));
    try expectError(error.OutOfMemory, reaper.init(std.testing.failing_allocator, io, 1));
    try equal(teardown.State.uninitialized, reaper.state);
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    try expectError(error.AlreadyInitialized, reaper.init(allocator, io, 1));
    try expectError(error.StopRequired, reaper.join());
    try expectError(error.StopRequired, reaper.tryJoin());
    try expectError(error.NotJoined, reaper.deinit());
    var invalid = session;
    invalid.owner = 0;
    try expectError(error.InvalidIdentity, reaper.reserve(invalid));
    invalid = session;
    invalid.generation = 0;
    try expectError(error.InvalidIdentity, reaper.reserve(invalid));
}

test "reservations bound connections and rejected submissions retain task ownership" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    const ticket = try reaper.reserve(session);
    try expectError(error.DuplicateSession, reaper.reserve(session));
    var other = session;
    other.generation += 1;
    try expectError(error.PoolFull, reaper.reserve(other));
    var context: Context = .{};
    var pending: ?teardown.Task = context.task(other);
    try expectError(error.WrongSession, reaper.submit(ticket, &pending));
    try expect(pending != null);
    pending = null;
    try expectError(error.EmptyTransfer, reaper.submit(ticket, &pending));
    try expectError(error.AliasedTask, reaper.submit(ticket, &reaper.records.get(ticket).?.task));
    try equal(teardown.Phase.reserved, try reaper.phase(ticket));
    try equal(@as(usize, 0), context.calls.load(.acquire));
    try reaper.cancelReservation(ticket);
    try expectError(error.StaleTicket, reaper.cancelReservation(ticket));
}

test "completion observation retains credits until quiesced context transfers back" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 9);
    defer cleanup(&reaper);
    var context: Context = .{};
    const ticket = try reaper.reserve(session);
    var pending: ?teardown.Task = context.task(session);
    try reaper.submit(ticket, &pending);
    try equal(null, pending);
    try expectError(error.NotQuiesced, reaper.takeFinalized(ticket));
    try expectError(error.NotReserved, reaper.cancelReservation(ticket));
    try expectError(error.NotFailed, reaper.retry(ticket));
    pending = context.task(session);
    try expectError(error.NotReserved, reaper.submit(ticket, &pending));
    try expect(pending != null);
    const completion = try next(&reaper);
    try equal(ticket, completion.ticket);
    try equal(session, completion.session);
    try equal(teardown.Outcome.quiesced, completion.outcome);
    try equal(@as(u32, 1), reaper.records.count);
    var other = session;
    other.index += 1;
    try expectError(error.PoolFull, reaper.reserve(other));
    const returned = try reaper.takeFinalized(ticket);
    try equal(@as(*anyopaque, &context), returned.context);
    try expect(context.completed.load(.acquire));
    try expectError(error.StaleTicket, reaper.takeFinalized(ticket));
    try equal(@as(usize, 1), context.calls.load(.acquire));
}

test "owner cannot join while a finalizer waits and polling does not wait for it" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    var context: Context = .{ .proceed = .init(false) };
    defer context.proceed.store(true, .release);
    const ticket = try reaper.reserve(session);
    var pending: ?teardown.Task = context.task(session);
    try reaper.submit(ticket, &pending);
    const start = std.Io.Clock.awake.now(io);
    while (!context.entered.load(.acquire)) {
        try deadline(start);
        try std.Thread.yield();
    }
    try equal(null, try reaper.collect());
    try reaper.requestStop();
    try expect(!try reaper.tryJoin());
    try expectError(error.WorkOutstanding, reaper.join());
    try expectError(error.Stopping, reaper.reserve(session));
    try expect(context.thread.load(.acquire) != std.Thread.getCurrentId());
    context.proceed.store(true, .release);
    const completion = try next(&reaper);
    try equal(teardown.Outcome.quiesced, completion.outcome);
    _ = try reaper.takeFinalized(ticket);
    try reaper.join();
    try expect(try reaper.tryJoin());
    try expectError(error.Closed, reaper.collect());
}

test "full completion queue preserves every finalizer outcome through shutdown" {
    var reaper: Reaper(4) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    var contexts: [4]Context = @splat(.{});
    contexts[0].proceed.store(false, .release);
    defer contexts[0].proceed.store(true, .release);
    var tickets: [4]Reaper(4).Ticket = undefined;
    for (&contexts, &tickets, 0..) |*context, *ticket, index| {
        var scope = session;
        scope.index = @intCast(index);
        ticket.* = try reaper.reserve(scope);
        var pending: ?teardown.Task = context.task(scope);
        try reaper.submit(ticket.*, &pending);
    }
    try reaper.requestStop();
    try reaper.requestStop();
    contexts[0].proceed.store(true, .release);
    const start = std.Io.Clock.awake.now(io);
    for (&contexts) |*context| {
        while (!context.completed.load(.acquire)) {
            try deadline(start);
            try std.Thread.yield();
        }
    }
    try equal(@as(u32, 4), reaper.records.count);
    try expect(!try reaper.tryJoin());
    for (tickets, &contexts) |ticket, *context| {
        const completion = try next(&reaper);
        try equal(ticket, completion.ticket);
        try equal(teardown.Outcome.quiesced, completion.outcome);
        try equal(@as(usize, 1), context.calls.load(.acquire));
        _ = try reaper.takeFinalized(ticket);
    }
    try reaper.join();
}

test "shutdown admits finalization for existing reservations and cancellation for unused ones" {
    var reaper: Reaper(2) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    const ticket = try reaper.reserve(session);
    var other = session;
    other.index += 1;
    const unused = try reaper.reserve(other);
    try reaper.requestStop();
    try expectError(error.WorkOutstanding, reaper.join());
    var context: Context = .{};
    var pending: ?teardown.Task = context.task(session);
    try reaper.submit(ticket, &pending);
    try reaper.cancelReservation(unused);
    try equal(teardown.Outcome.quiesced, (try next(&reaper)).outcome);
    _ = try reaper.takeFinalized(ticket);
    try reaper.join();
}

test "failed provider contexts retain ownership and retry during shutdown" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    var context: Context = .{ .failures = 1 };
    const ticket = try reaper.reserve(session);
    var pending: ?teardown.Task = context.task(session);
    try reaper.submit(ticket, &pending);
    try equal(teardown.Outcome.failed, (try next(&reaper)).outcome);
    try equal(teardown.Phase.failed, try reaper.phase(ticket));
    try expectError(error.NotQuiesced, reaper.takeFinalized(ticket));
    try expectError(error.NotReserved, reaper.cancelReservation(ticket));
    try reaper.requestStop();
    try expect(!try reaper.tryJoin());
    try expectError(error.WorkOutstanding, reaper.join());
    try reaper.retry(ticket);
    try equal(teardown.Outcome.quiesced, (try next(&reaper)).outcome);
    try equal(@as(usize, 2), context.calls.load(.acquire));
    _ = try reaper.takeFinalized(ticket);
    try reaper.join();
}

test "stale tickets cannot finalize replacement contexts or move a caller task" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    const old = try reaper.reserve(session);
    try reaper.cancelReservation(old);
    const current = try reaper.reserve(session);
    try expect(current.generation != old.generation);
    var context: Context = .{};
    for ([_]Reaper(1).Ticket{ old, .{ .owner = 2, .index = 0, .generation = current.generation }, .{ .owner = 1, .index = 99, .generation = current.generation } }) |stale| {
        var pending: ?teardown.Task = context.task(session);
        try expectError(error.StaleTicket, reaper.submit(stale, &pending));
        try expectError(error.StaleTicket, reaper.retry(stale));
        try expectError(error.StaleTicket, reaper.cancelReservation(stale));
        try expectError(error.StaleTicket, reaper.takeFinalized(stale));
        try expect(pending != null);
    }
    try equal(@as(usize, 0), context.calls.load(.acquire));
    try equal(teardown.Phase.reserved, try reaper.phase(current));
}

test "ticket generation exhaustion retires its cleanup credit" {
    var reaper: Reaper(1) = .{};
    try reaper.init(allocator, io, 1);
    defer cleanup(&reaper);
    reaper.records.slots[0].generation = std.math.maxInt(u64);
    const ticket = try reaper.reserve(session);
    try reaper.cancelReservation(ticket);
    try expectError(error.PoolFull, reaper.reserve(session));
    try expectError(error.StaleTicket, reaper.phase(ticket));
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var reaper: Reaper(1) = .{};
    try reaper.init(gpa, io, 1);
    defer cleanup(&reaper);
    var context: Context = .{};
    const ticket = try reaper.reserve(session);
    var pending: ?teardown.Task = context.task(session);
    try reaper.submit(ticket, &pending);
    _ = try next(&reaper);
    _ = try reaper.takeFinalized(ticket);
}

test "reaper owner record allocation failures leave no allocation or live worker" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}
