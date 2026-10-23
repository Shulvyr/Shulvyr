const std = @import("std");
const out = @import("Outbox.zig");
const Outbox = out.Outbox;
const Session = @import("Session.zig");
const framing = @import("framing.zig");
const FrameSink = @import("FrameSink.zig");
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const id: Session.Id = .{ .owner = 5, .index = 0, .generation = 3 };
const config: out.Config = .{ .limits = .{ .{ .frame_bytes = 5, .message_bytes = 32 }, .{ .frame_bytes = 5, .message_bytes = 32 } }, .payload_bytes = 32, .buffered_bytes = 8 };
const budget: out.Budget = .{ .steps = 64, .wire_bytes = 256 };

const Fixture = struct {
    reliable: [32]u8 = undefined,
    unreliable: [4]u8 = undefined,

    fn session(self: *@This()) !Session {
        var value = try Session.init(id, &self.reliable, &self.unreliable, config.limits[0], 0, 100);
        try value.channelOpened(id, .reliable, .{ .ordered = true }, 0);
        try value.channelOpened(id, .unreliable, .{ .ordered = false, .max_retransmits = 0 }, 0);
        return value;
    }
};

const Fake = struct {
    const Frame = struct { channel: framing.Channel, bytes: [32]u8, length: usize };
    session_id: Session.Id = id,
    buffered: [2]u64 = .{ 0, 0 },
    block: [2]bool = .{ false, false },
    frames: [128]Frame = undefined,
    frame_count: usize = 0,
    queries: usize = 0,
    sends: usize = 0,
    fail_send_at: ?usize = null,
    fail_query: bool = false,
    closed: bool = false,
    auto_drain: bool = false,

    fn get(raw: *anyopaque, channel: framing.Channel) FrameSink.Error!u64 {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.queries += 1;
        if (self.closed) return error.Closed;
        if (self.fail_query) return error.Failed;
        return self.buffered[@backingInt(channel)];
    }

    fn send(raw: *anyopaque, channel: framing.Channel, bytes: []const u8) FrameSink.Error!FrameSink.Admission {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.sends += 1;
        if (self.closed) return error.Closed;
        if (self.fail_send_at == self.frame_count) return error.Failed;
        if (self.block[@backingInt(channel)]) return .blocked;
        if (self.frame_count == self.frames.len or bytes.len > 32) return error.Failed;
        var frame: Frame = .{ .channel = channel, .bytes = @splat(0), .length = bytes.len };
        @memcpy(frame.bytes[0..bytes.len], bytes);
        self.frames[self.frame_count] = frame;
        self.frame_count += 1;
        if (!self.auto_drain) self.buffered[@backingInt(channel)] += bytes.len;
        return .accepted;
    }

    fn sink(self: *Fake) FrameSink {
        return .{ .session_id = self.session_id, .context = self, .buffered = get, .send = send };
    }

    fn expectFrame(self: *const Fake, index: usize, channel: framing.Channel, bytes: []const u8) !void {
        try equal(channel, self.frames[index].channel);
        try std.testing.expectEqualSlices(u8, bytes, self.frames[index].bytes[0..self.frames[index].length]);
    }
};

test "outbox retains ownership on admission failure and counts outstanding completions" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(1).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    var source = [_]u8{ 97, 98, 99 };
    var pending: ?OwnedBytes = try .copy(allocator, &source, 3);
    defer if (pending) |*bytes| bytes.deinit();
    const ticket = try queue.enqueueOwned(&session, .reliable, &pending);
    try equal(null, pending);
    @memset(&source, 0);
    try equal(@as(usize, 3), queue.retained_bytes);
    try expectError(error.QueueFull, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "x"));
    var fake: Fake = .{ .auto_drain = true };
    var scratch: [5]u8 = undefined;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try fake.expectFrame(0, .reliable, "\x00abc");
    try equal(@as(usize, 0), queue.retained_bytes);
    try expectError(error.QueueFull, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "x"));
    const completion = queue.takeCompletion().?;
    try equal(ticket, completion.ticket);
    try equal(out.Outcome.drained, completion.outcome);
    try equal(@as(usize, 4), completion.wire_bytes);
    try equal(@as(u16, 1), completion.frames);
    try equal(null, queue.takeCompletion());
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "next");
}

test "per-channel admission bypasses a blocked reliable queue without interleaving its messages" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(4).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcdef");
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "Z");
    const fast = try queue.enqueueCopy(allocator, &session, .unreliable, "uv");
    var fake: Fake = .{ .block = .{ true, false } };
    var scratch: [5]u8 = undefined;
    const blocked = try queue.pump(&session, fake.sink(), &scratch, budget);
    try expect(blocked.blocked[0]);
    try equal(@as(usize, 1), fake.frame_count);
    try fake.expectFrame(0, .unreliable, "\x00uv");
    try equal(@as(usize, 7), queue.retained_bytes);
    fake.buffered[1] = 0;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try equal(fast, queue.takeCompletion().?.ticket);
    fake.block[0] = false;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try fake.expectFrame(1, .reliable, "\x01abcd");
    try fake.expectFrame(2, .reliable, "\x00ef");
    try equal(@as(u64, 8), fake.buffered[0]);
    try equal(@as(usize, 1), queue.retained_bytes);
    fake.buffered[0] = 0;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try fake.expectFrame(3, .reliable, "\x00Z");
    try equal(@as(u64, 1), queue.takeCompletion().?.ticket.sequence);
    try equal(null, queue.takeCompletion());
    fake.buffered[0] = 0;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try equal(@as(u64, 2), queue.takeCompletion().?.ticket.sequence);
    try equal(@as(usize, 0), queue.outstanding);
}

test "payload and complete-message wire reservations reject before allocation or transfer" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var settings = config;
    settings.payload_bytes = 4;
    var queue = try Outbox(4).init(id, settings);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcd");
    try expectError(error.PayloadBudgetExceeded, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "x"));
    var pending: ?OwnedBytes = try .copy(allocator, "x", 1);
    defer if (pending) |*bytes| bytes.deinit();
    try expectError(error.PayloadBudgetExceeded, queue.enqueueOwned(&session, .reliable, &pending));
    try std.testing.expectEqualStrings("x", pending.?.bytes());
    try expectError(error.UnreliableFragmentation, queue.enqueueCopy(std.testing.failing_allocator, &session, .unreliable, "abcde"));
    try equal(@as(usize, 1), queue.outstanding);
}

test "pump budgets bound frames and provider calls while preserving pending fragment position" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcdef");
    var fake: Fake = .{ .auto_drain = true };
    var scratch: [5]u8 = undefined;
    const none = try queue.pump(&session, fake.sink(), &.{}, .{ .steps = 0, .wire_bytes = 0 });
    try expect(none.budget_limited);
    try equal(@as(usize, 0), fake.queries);
    const small = try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 1, .wire_bytes = 4 });
    try expect(small.budget_limited);
    try equal(@as(usize, 0), fake.frame_count);
    const first = try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 1, .wire_bytes = 5 });
    try equal(@as(usize, 1), first.frames);
    try equal(@as(usize, 1), first.steps);
    try fake.expectFrame(0, .reliable, "\x01abcd");
    const second = try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 1, .wire_bytes = 3 });
    try equal(@as(usize, 1), second.frames);
    try fake.expectFrame(1, .reliable, "\x00ef");
    try equal(null, queue.takeCompletion());
    const done = try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 1, .wire_bytes = 0 });
    try equal(@as(usize, 1), done.completions);
    try equal(out.Outcome.drained, queue.takeCompletion().?.outcome);
    try expect(fake.queries + fake.sends <= 3 * 4);
}

test "provider failure after a partial reliable send closes the session and releases every queued payload" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(3).init(id, config);
    defer queue.deinit();
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcdef");
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "later");
    _ = try queue.enqueueCopy(allocator, &session, .unreliable, "uv");
    var fake: Fake = .{ .auto_drain = true, .fail_send_at = 1 };
    var scratch: [5]u8 = undefined;
    try expectError(error.ProviderFailed, queue.pump(&session, fake.sink(), &scratch, budget));
    try equal(Session.State.closed, session.state);
    try equal(Session.CloseReason.outbound_failure, session.close_reason.?);
    try equal(@as(usize, 0), queue.retained_bytes);
    try equal(@as(usize, 1), fake.frame_count);
    var count: usize = 0;
    while (queue.takeCompletion()) |completion| {
        try equal(out.Outcome.failed, completion.outcome);
        if (completion.ticket.sequence == 1) try equal(@as(u16, 1), completion.frames);
        count += 1;
    }
    try equal(@as(usize, 3), count);
    try expect((try queue.pump(&session, fake.sink(), &scratch, budget)).stopped);
}

test "shutdown cannot lose completions even when finished results occupy every other slot" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "x");
    var fake: Fake = .{ .auto_drain = true };
    var scratch: [5]u8 = undefined;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcdef");
    _ = try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 1, .wire_bytes = 5 });
    try queue.shutdown(&session);
    try queue.shutdown(&session);
    try equal(@as(usize, 0), queue.retained_bytes);
    try equal(out.Outcome.drained, queue.takeCompletion().?.outcome);
    const cancelled = queue.takeCompletion().?;
    try equal(out.Outcome.cancelled, cancelled.outcome);
    try equal(@as(u16, 1), cancelled.frames);
    try equal(null, queue.takeCompletion());
}

test "empty payload receipts wait for the provider observation and do not consume wire budget" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "");
    var fake: Fake = .{ .buffered = .{ 100, 0 } };
    _ = try queue.pump(&session, fake.sink(), &.{}, budget);
    try equal(null, queue.takeCompletion());
    try equal(@as(usize, 0), fake.sends);
    fake.buffered[0] = 0;
    _ = try queue.pump(&session, fake.sink(), &.{}, .{ .steps = 1, .wire_bytes = 0 });
    const done = queue.takeCompletion().?;
    try equal(out.Outcome.drained, done.outcome);
    try equal(@as(usize, 0), done.wire_bytes);
    try equal(@as(u16, 0), done.frames);
}

test "stale session operations cannot mutate a replacement or consume payload ownership" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "old");
    var replacement = session;
    replacement.id.generation += 1;
    var pending: ?OwnedBytes = null;
    try expectError(error.StaleSession, queue.enqueueOwned(&replacement, .reliable, &pending));
    try expectError(error.StaleSession, queue.shutdown(&replacement));
    var fake: Fake = .{};
    try expectError(error.StaleSession, queue.pump(&replacement, fake.sink(), &.{}, budget));
    fake.session_id.generation += 1;
    try expectError(error.StaleProvider, queue.pump(&session, fake.sink(), &.{}, budget));
    try equal(Session.State.open, replacement.state);
    try equal(@as(usize, 3), queue.retained_bytes);
    try equal(@as(usize, 0), fake.queries);
}

test "scratch cannot overwrite metadata, receiver buffers or a future queued payload" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(3).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "head");
    var pending: ?OwnedBytes = try .copy(allocator, "future", 6);
    const future_storage = pending.?.storage;
    _ = try queue.enqueueOwned(&session, .reliable, &pending);
    var fake: Fake = .{};
    try expectError(error.AliasedScratch, queue.pump(&session, fake.sink(), future_storage, budget));
    try expectError(error.AliasedScratch, queue.pump(&session, fake.sink(), std.mem.asBytes(&queue), budget));
    try expectError(error.AliasedScratch, queue.pump(&session, fake.sink(), &fixture.reliable, budget));
    var small: [4]u8 = undefined;
    try expectError(error.NoSpace, queue.pump(&session, fake.sink(), &small, budget));
    try std.testing.expectEqualStrings("future", future_storage);
    try equal(@as(usize, 0), fake.queries);
}

test "ticket and cumulative wire counters reject overflow before moving a payload" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(3).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    queue.reserved[0] = std.math.maxInt(u64) - 2;
    queue.queued[0] = queue.reserved[0];
    try expectError(error.CounterExhausted, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "ab"));
    queue.next_sequence = std.math.maxInt(u64);
    const ticket = try queue.enqueueCopy(allocator, &session, .reliable, "a");
    try equal(std.math.maxInt(u64), ticket.sequence);
    try expectError(error.CounterExhausted, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, ""));
}

test "reported native buffer overflow and closed providers fail without unsafe arithmetic" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "x");
    var fake: Fake = .{ .buffered = .{ std.math.maxInt(u64), 0 } };
    var scratch: [5]u8 = undefined;
    try expect((try queue.pump(&session, fake.sink(), &scratch, budget)).blocked[0]);
    try equal(@as(usize, 0), fake.sends);
    fake.closed = true;
    try expectError(error.ProviderClosed, queue.pump(&session, fake.sink(), &scratch, budget));
    try equal(Session.CloseReason.transport_closed, session.close_reason.?);
    try equal(out.Outcome.failed, queue.takeCompletion().?.outcome);
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(3).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(gpa, &session, .reliable, "abcdef");
    _ = try queue.enqueueCopy(gpa, &session, .unreliable, "uv");
    var fake: Fake = .{ .auto_drain = true };
    var scratch: [5]u8 = undefined;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try equal(@as(usize, 0), queue.retained_bytes);
    var count: usize = 0;
    while (queue.takeCompletion()) |_| count += 1;
    try equal(@as(usize, 2), count);
}

test "allocation failures release prior queue ownership and preserve admission counts" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(1).init(id, config);
    defer queue.deinit();
    try expectError(error.OutOfMemory, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "x"));
    try equal(@as(usize, 0), queue.outstanding);
    try equal(@as(u64, 1), queue.next_sequence);
}

test "reported queue budget is shared across both native channels" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "abcd");
    var fake: Fake = .{ .buffered = .{ 0, 4 } };
    var scratch: [5]u8 = undefined;
    try expect((try queue.pump(&session, fake.sink(), &scratch, budget)).blocked[0]);
    try equal(@as(usize, 0), fake.sends);
    fake.buffered[1] = 3;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try equal(@as(usize, 1), fake.frame_count);
    try equal(@as(u64, 5), fake.buffered[0]);
    try equal(@as(u64, 8), fake.buffered[0] + fake.buffered[1]);
}

test "duplicate owning views and session storage cannot enter the outbox" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(3).init(id, config);
    defer queue.deinit();
    defer queue.shutdown(&session) catch unreachable;
    var pending: ?OwnedBytes = try .copy(allocator, "owned", 5);
    const alias = pending.?.storage;
    _ = try queue.enqueueOwned(&session, .reliable, &pending);
    // Non-owning test views model an accidental duplicate without double freeing.
    var duplicate: ?OwnedBytes = .{ .storage = alias };
    try expectError(error.AliasedPayload, queue.enqueueOwned(&session, .reliable, &duplicate));
    try expect(duplicate != null);
    duplicate = .{ .storage = fixture.reliable[0..4] };
    try expectError(error.AliasedPayload, queue.enqueueOwned(&session, .reliable, &duplicate));
    try equal(@as(usize, 1), queue.outstanding);
}

test "logical closure cancels unresolved receipts without calling a dead provider" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var queue = try Outbox(2).init(id, config);
    defer queue.deinit();
    _ = try queue.enqueueCopy(allocator, &session, .reliable, "x");
    var fake: Fake = .{};
    var scratch: [5]u8 = undefined;
    _ = try queue.pump(&session, fake.sink(), &scratch, budget);
    try equal(@as(usize, 0), queue.retained_bytes);
    const queries = fake.queries;
    try session.close(id, .transport_closed);
    fake.fail_query = true;
    try expect((try queue.pump(&session, fake.sink(), &scratch, .{ .steps = 0, .wire_bytes = 0 })).stopped);
    try equal(queries, fake.queries);
    try equal(out.Outcome.cancelled, queue.takeCompletion().?.outcome);
}

test "local admission configuration and negotiating sessions reject without allocation" {
    var fixture: Fixture = .{};
    var session = try fixture.session();
    var invalid = config;
    invalid.payload_bytes = 0;
    try expectError(error.InvalidBudget, Outbox(1).init(id, invalid));
    invalid = config;
    invalid.buffered_bytes = 4;
    try expectError(error.InvalidBudget, Outbox(1).init(id, invalid));
    var queue = try Outbox(1).init(id, config);
    defer queue.deinit();
    session.state = .negotiating;
    try expectError(error.NotOpen, queue.enqueueCopy(std.testing.failing_allocator, &session, .reliable, "x"));
    var pending: ?OwnedBytes = null;
    try expectError(error.EmptyTransfer, queue.enqueueOwned(&session, .reliable, &pending));
    try equal(@as(usize, 0), queue.outstanding);
}

test "receipt drain checkpoints match the actual Axolotl Session with its upstream test transports" {
    const Oracle = struct {
        oracle: std.json.Value,
        cases: []const struct {
            name: []const u8,
            packets: []const struct { payload_hex: []const u8, reliable: bool },
            control_buffered: [2]u64,
            phases: []const struct { buffered: [2]u64, acknowledged: []const u64 },
        },
    };
    const fixtures = try std.json.parseFromSlice(Oracle, allocator, @embedFile("fixtures/receipts.json"), .{});
    defer fixtures.deinit();
    for (fixtures.value.cases) |case| {
        var fixture: Fixture = .{};
        var session = try fixture.session();
        var settings = config;
        settings.buffered_bytes = 128;
        var queue = try Outbox(8).init(id, settings);
        defer queue.deinit();
        defer queue.shutdown(&session) catch unreachable;
        for (case.packets) |packet| {
            var bytes: [32]u8 = undefined;
            const payload = try std.fmt.hexToBytes(&bytes, packet.payload_hex);
            _ = try queue.enqueueCopy(allocator, &session, if (packet.reliable) .reliable else .unreliable, payload);
        }
        var fake: Fake = .{ .buffered = case.control_buffered };
        var scratch: [5]u8 = undefined;
        _ = try queue.pump(&session, fake.sink(), &scratch, budget);
        var last: [2]u64 = .{ 0, 0 };
        for (case.phases) |phase| {
            fake.buffered = phase.buffered;
            _ = try queue.pump(&session, fake.sink(), &scratch, budget);
            var mask: u64 = 0;
            var count: usize = 0;
            while (queue.takeCompletion()) |completion| {
                try equal(out.Outcome.drained, completion.outcome);
                const sequence = completion.ticket.sequence;
                try expect(sequence >= 1 and sequence <= case.packets.len);
                const channel = @backingInt(completion.channel);
                try expect(sequence > last[channel]);
                last[channel] = sequence;
                mask |= @as(u64, 1) << @as(u6, @intCast(sequence - 1));
                count += 1;
            }
            var expected: u64 = 0;
            for (phase.acknowledged) |sequence| expected |= @as(u64, 1) << @as(u6, @intCast(sequence - 1));
            try equal(phase.acknowledged.len, count);
            try equal(expected, mask);
        }
        try equal(@as(usize, 0), queue.outstanding);
    }
}
