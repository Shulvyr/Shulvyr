const std = @import("std");
const Queue = @import("../foundation/Queue.zig").Queue;
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const framing = @import("framing.zig");
const Session = @import("Session.zig");
const FrameSink = @import("FrameSink.zig");
const buffer = @import("buffer.zig");

pub const Config = struct {
    limits: [2]framing.Limits = .{ .{}, .{} },
    payload_bytes: usize = 4 * 1024 * 1024,
    buffered_bytes: u64 = 4 * 1024 * 1024,
};
pub const Budget = struct { steps: usize, wire_bytes: usize };
pub const Stats = struct {
    steps: usize = 0,
    frames: usize = 0,
    wire_bytes: usize = 0,
    completions: usize = 0,
    blocked: [2]bool = .{ false, false },
    budget_limited: bool = false,
    stopped: bool = false,
};
pub const Ticket = struct { session: Session.Id, sequence: u64 };
pub const Outcome = enum { drained, cancelled, failed };
pub const Completion = struct {
    ticket: Ticket,
    channel: framing.Channel,
    outcome: Outcome,
    payload_bytes: usize,
    wire_bytes: usize,
    frames: u16,
};

/// One owner and one outbox per session lifetime. Payloads move on admission.
/// Count capacity includes messages, drain receipts and unconsumed completions.
/// Shutdown before discarding pending work. Do not copy a live outbox.
pub fn Outbox(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 4096) @compileError("Outbox requires 1 through 4096 slots");
    return struct {
        const Self = @This();
        const Entry = struct {
            ticket: Ticket,
            channel: framing.Channel,
            payload: OwnedBytes,
            sender: framing.Sender,
            watermark: u64,
            wire_bytes: usize = 0,
            frames: u16 = 0,
        };
        const Receipt = struct { completion: Completion, watermark: u64 };
        const Plan = struct { sender: framing.Sender, watermark: u64 };

        session_id: Session.Id,
        config: Config,
        messages: [2]Queue(Entry, capacity) = .{ .{}, .{} },
        receipts: [2]Queue(Receipt, capacity) = .{ .{}, .{} },
        completed: Queue(Completion, capacity) = .{},
        retained_bytes: usize = 0,
        outstanding: usize = 0,
        next_sequence: u64 = 1,
        reserved: [2]u64 = .{ 0, 0 },
        queued: [2]u64 = .{ 0, 0 },
        drained: [2]u64 = .{ 0, 0 },
        turn: u1 = 0,
        closed: bool = false,

        pub fn init(session_id: Session.Id, config: Config) !Self {
            if (session_id.owner == 0 or session_id.generation == 0) return error.InvalidIdentity;
            for (config.limits) |limits| try limits.validate();
            if (config.payload_bytes == 0 or config.buffered_bytes < @max(config.limits[0].frame_bytes, config.limits[1].frame_bytes))
                return error.InvalidBudget;
            return .{ .session_id = session_id, .config = config };
        }

        /// Payloads must already have been released by normal completion or
        /// shutdown. Completions contain no owned allocations and may be discarded.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.messages[0].count + self.messages[1].count == 0);
            std.debug.assert(self.receipts[0].count + self.receipts[1].count == 0);
            self.* = undefined;
        }

        fn identity(self: *const Self, session: *const Session) error{StaleSession}!void {
            if (!std.meta.eql(self.session_id, session.id)) return error.StaleSession;
        }

        fn plan(self: *const Self, session: *const Session, channel: framing.Channel, input: []const u8) !Plan {
            try self.identity(session);
            if (self.closed or session.state == .closed) return error.Closed;
            if (session.state != .open) return error.NotOpen;
            const index = @backingInt(channel);
            const sender = try framing.Sender.init(channel, input, self.config.limits[index]);
            if (self.outstanding == capacity) return error.QueueFull;
            if (input.len > self.config.payload_bytes - self.retained_bytes) return error.PayloadBudgetExceeded;
            if (self.next_sequence == 0) return error.CounterExhausted;
            const wire_bytes = @as(u64, @intCast(input.len)) + sender.remaining;
            const watermark = std.math.add(u64, self.reserved[index], wire_bytes) catch return error.CounterExhausted;
            return .{ .sender = sender, .watermark = watermark };
        }

        /// Failure retains ownership with the caller. All capacity checks precede
        /// the move, including completion space and complete-message wire counters.
        pub fn enqueueOwned(self: *Self, session: *const Session, channel: framing.Channel, pending: *?OwnedBytes) !Ticket {
            try self.identity(session);
            if (buffer.overlaps(std.mem.asBytes(pending), std.mem.asBytes(self))) return error.AliasedPayload;
            const value = pending.* orelse return error.EmptyTransfer;
            const prepared = try self.plan(session, channel, value.bytes());
            if (buffer.overlaps(value.bytes(), std.mem.asBytes(self)) or
                buffer.overlaps(value.bytes(), std.mem.asBytes(session))) return error.AliasedPayload;
            for (session.receivers) |receiver| {
                if (buffer.overlaps(value.bytes(), receiver.storage)) return error.AliasedPayload;
            }
            for (&self.messages) |*queue| {
                var offset: usize = 0;
                while (offset < queue.count) : (offset += 1) {
                    const entry = &queue.items[(queue.head + offset) % capacity];
                    if (buffer.overlaps(value.bytes(), entry.payload.bytes())) return error.AliasedPayload;
                }
            }
            const ticket: Ticket = .{ .session = self.session_id, .sequence = self.next_sequence };
            const index = @backingInt(channel);
            self.messages[index].push(.{ .ticket = ticket, .channel = channel, .payload = value, .sender = prepared.sender, .watermark = prepared.watermark }) catch unreachable;
            pending.* = null;
            self.retained_bytes += value.bytes().len;
            self.outstanding += 1;
            self.reserved[index] = prepared.watermark;
            self.next_sequence = if (self.next_sequence == std.math.maxInt(u64)) 0 else self.next_sequence + 1;
            return ticket;
        }

        /// Admission checks run before allocation. The allocator must outlive
        /// queued payloads and its allocation overhead is outside payload accounting.
        pub fn enqueueCopy(self: *Self, allocator: std.mem.Allocator, session: *const Session, channel: framing.Channel, input: []const u8) !Ticket {
            _ = try self.plan(session, channel, input);
            var pending: ?OwnedBytes = try OwnedBytes.copy(allocator, input, self.config.limits[@backingInt(channel)].message_bytes);
            errdefer if (pending) |*payload| payload.deinit();
            return self.enqueueOwned(session, channel, &pending);
        }

        pub fn takeCompletion(self: *Self) ?Completion {
            const completion = self.completed.pop() orelse return null;
            self.outstanding -= 1;
            return completion;
        }

        fn finishSubmission(self: *Self, index: usize) void {
            var entry = self.messages[index].pop().?;
            const completion: Completion = .{ .ticket = entry.ticket, .channel = entry.channel, .outcome = .drained, .payload_bytes = entry.payload.bytes().len, .wire_bytes = entry.wire_bytes, .frames = entry.frames };
            self.retained_bytes -= entry.payload.bytes().len;
            entry.payload.deinit();
            self.receipts[index].push(.{ .completion = completion, .watermark = entry.watermark }) catch unreachable;
        }

        fn cancelRemaining(self: *Self, outcome: Outcome) void {
            self.closed = true;
            for (0..2) |index| {
                while (self.receipts[index].pop()) |receipt| {
                    var completion = receipt.completion;
                    completion.outcome = outcome;
                    self.completed.push(completion) catch unreachable;
                }
                while (self.messages[index].pop()) |value| {
                    var entry = value;
                    const completion: Completion = .{ .ticket = entry.ticket, .channel = entry.channel, .outcome = outcome, .payload_bytes = entry.payload.bytes().len, .wire_bytes = entry.wire_bytes, .frames = entry.frames };
                    self.retained_bytes -= entry.payload.bytes().len;
                    entry.payload.deinit();
                    self.completed.push(completion) catch unreachable;
                }
            }
        }

        /// Closes the logical session and cancels all unresolved sends. The owner
        /// must close the native peer as well, especially after partial sends.
        pub fn shutdown(self: *Self, session: *Session) error{StaleSession}!void {
            try self.identity(session);
            try session.close(self.session_id, .requested);
            self.cancelRemaining(.cancelled);
        }

        fn failed(self: *Self, session: *Session, cause: FrameSink.Error) error{ ProviderClosed, ProviderFailed } {
            session.close(self.session_id, if (cause == error.Closed) .transport_closed else .outbound_failure) catch unreachable;
            self.cancelRemaining(.failed);
            return if (cause == error.Closed) error.ProviderClosed else error.ProviderFailed;
        }

        pub fn checkScratch(self: *Self, session: *const Session, scratch: []u8) !void {
            if (buffer.overlaps(scratch, std.mem.asBytes(self)) or
                buffer.overlaps(scratch, std.mem.asBytes(session))) return error.AliasedScratch;
            for (session.receivers) |receiver| {
                if (buffer.overlaps(scratch, receiver.storage)) return error.AliasedScratch;
            }
            var has_bytes = false;
            for (&self.messages) |*queue| {
                var offset: usize = 0;
                while (offset < queue.count) : (offset += 1) {
                    const entry = &queue.items[(queue.head + offset) % capacity];
                    has_bytes = has_bytes or entry.payload.bytes().len != 0;
                    if (buffer.overlaps(scratch, entry.payload.bytes())) return error.AliasedScratch;
                }
            }
            if (has_bytes and scratch.len < @max(self.config.limits[0].frame_bytes, self.config.limits[1].frame_bytes))
                return error.NoSpace;
        }

        /// One step completes one receipt, moves an empty message, or observes
        /// the queues and may submit one frame. At most three sink calls per step.
        /// The single producer owns all application sends to these native channels.
        pub fn pump(self: *Self, session: *Session, sink: FrameSink, scratch: []u8, budget: Budget) !Stats {
            try self.identity(session);
            if (!std.meta.eql(sink.session_id, self.session_id)) return error.StaleProvider;
            var stats: Stats = .{};
            if (self.closed or session.state == .closed) {
                self.cancelRemaining(.cancelled);
                stats.stopped = true;
                return stats;
            }
            if (session.state != .open) return error.NotOpen;
            if (budget.steps == 0) {
                stats.budget_limited = self.outstanding != self.completed.count;
                return stats;
            }
            try self.checkScratch(session, scratch);
            var skip: [2]bool = .{ false, false };
            var observed: [2]bool = .{ false, false };
            while (stats.steps < budget.steps) {
                var index: usize = self.turn;
                if (skip[index] or self.messages[index].count + self.receipts[index].count == 0) index = 1 - index;
                if (skip[index] or self.messages[index].count + self.receipts[index].count == 0) break;
                self.turn = @intCast(1 - index);
                stats.steps += 1;
                const channel: framing.Channel = @fromBackingInt(@intCast(index));
                if (self.receipts[index].peek()) |receipt| {
                    if (observed[index] and receipt.watermark <= self.drained[index]) {
                        self.completed.push(self.receipts[index].pop().?.completion) catch unreachable;
                        stats.completions += 1;
                        continue;
                    }
                }
                if (self.messages[index].peek()) |entry| {
                    if (entry.sender.done()) {
                        self.finishSubmission(index);
                        continue;
                    }
                }
                const buffered = sink.bufferedAmount(channel) catch |err| return self.failed(session, err);
                observed[index] = buffered <= self.queued[index];
                self.drained[index] = self.queued[index] - @min(self.queued[index], buffered);
                if (self.receipts[index].peek()) |receipt| {
                    if (observed[index] and receipt.watermark <= self.drained[index]) {
                        self.completed.push(self.receipts[index].pop().?.completion) catch unreachable;
                        stats.completions += 1;
                        continue;
                    }
                }
                const entry = self.messages[index].peek() orelse {
                    skip[index] = true;
                    stats.blocked[index] = true;
                    continue;
                };
                const frame_length = @min(entry.sender.payload_bytes, entry.sender.input.len - entry.sender.position) + 1;
                if (frame_length > budget.wire_bytes - stats.wire_bytes) {
                    skip[index] = true;
                    stats.budget_limited = true;
                    continue;
                }
                const other_buffered = sink.bufferedAmount(@fromBackingInt(@intCast(1 - index))) catch |err| return self.failed(session, err);
                if (buffered > self.config.buffered_bytes or other_buffered > self.config.buffered_bytes - buffered or
                    frame_length > self.config.buffered_bytes - buffered - other_buffered)
                {
                    skip[index] = true;
                    stats.blocked[index] = true;
                    continue;
                }
                const frame = (try entry.sender.write(scratch)).?;
                const admission = sink.trySend(channel, frame) catch |err| return self.failed(session, err);
                if (admission == .blocked) {
                    skip[index] = true;
                    stats.blocked[index] = true;
                    continue;
                }
                self.queued[index] += frame.len;
                entry.wire_bytes += frame.len;
                entry.frames += 1;
                const committed = entry.sender.commit();
                std.debug.assert(committed);
                observed[index] = false;
                stats.frames += 1;
                stats.wire_bytes += frame.len;
                if (entry.sender.done()) self.finishSubmission(index);
            }
            if (stats.steps == budget.steps and self.outstanding != self.completed.count) stats.budget_limited = true;
            return stats;
        }

        /// Observes existing receipts without sending. Two provider queries at
        /// most, followed by at most capacity scalar completions. Providers may
        /// report final buffering after channel closure, before handle deletion.
        pub fn observeDrains(self: *Self, session: *Session, sink: FrameSink) !usize {
            try self.identity(session);
            if (!std.meta.eql(sink.session_id, self.session_id)) return error.StaleProvider;
            if (self.closed or session.state == .closed) return error.Closed;
            var count: usize = 0;
            for (0..2) |index| {
                if (self.receipts[index].count == 0) continue;
                const amount = sink.bufferedAmount(@fromBackingInt(@intCast(index))) catch |err| return self.failed(session, err);
                if (amount > self.queued[index]) continue;
                self.drained[index] = self.queued[index] - amount;
                while (self.receipts[index].peek()) |receipt| {
                    if (receipt.watermark > self.drained[index]) break;
                    self.completed.push(self.receipts[index].pop().?.completion) catch unreachable;
                    count += 1;
                }
            }
            return count;
        }
    };
}
