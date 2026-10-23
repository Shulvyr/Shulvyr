const std = @import("std");
const Session = @import("Session.zig");
const framing = @import("framing.zig");
const inbound = @import("Inbox.zig");
const outbound = @import("Outbox.zig");
const teardown = @import("Reaper.zig");
const FrameSink = @import("FrameSink.zig");
const OwnedBytes = @import("../foundation/OwnedBytes.zig");
const buffer = @import("buffer.zig");

pub const packet_limit = 64;
pub const flush_timeout_ns = 2 * std.time.ns_per_s;
pub const Config = struct {
    receive: framing.Limits = .{ .message_bytes = 256 * 9999 },
    incoming_bytes: usize = 256 * 10000,
    outgoing: outbound.Config = .{ .limits = .{ .{ .message_bytes = 256 * 9999 }, .{ .message_bytes = 256 * 9999 } } },
    negotiation_timeout_ns: u64 = 10 * std.time.ns_per_s,

    pub fn validate(self: Config) !void {
        try self.receive.validate();
        try self.outgoing.validate();
        if (self.incoming_bytes < self.receive.frame_bytes) return error.InvalidBudget;
        if (self.negotiation_timeout_ns == 0) return error.InvalidTimeout;
    }
};
pub const Budget = struct {
    send: outbound.Budget,
    receive_frames: usize,
    receive_bytes: usize,
    discard_frames: usize,
};
pub const Phase = enum { uninitialized, reserved, negotiating, open, draining, closing, retired };
pub const Provider = struct { sink: FrameSink, finalizer: teardown.Task };
pub const Event = union(enum) {
    opened: Session.Id,
    message: struct { session: Session.Id, channel: framing.Channel, payload: []const u8 },
    sent: outbound.Completion,
    closed: struct { session: Session.Id, reason: Session.CloseReason, flush_expired: bool },
    cleanup_failed: Session.Id,
    finalized: struct { session: Session.Id, task: ?teardown.Task },

    pub fn sessionId(self: Event) Session.Id {
        return switch (self) {
            .opened, .cleanup_failed => |id| id,
            .sent => |completion| completion.ticket.session,
            .message => |message| message.session,
            .closed => |closed| closed.session,
            .finalized => |done| done.session,
        };
    }
};
pub const Stats = struct { sent: outbound.Stats = .{}, drain_completions: usize = 0, frames: usize = 0, bytes: usize = 0, packets: usize = 0, receive_limited: bool = false };

/// One owner and one fixed address through native quiescence. Initialize before
/// binding a provider, and attach its finalizer before publishing callbacks.
/// Storage and allocator outlive deinit. The allocator is callback-thread safe.
pub fn Connection(comptime send_capacity: usize, comptime receive_capacity: usize, comptime reaper_capacity: usize) type {
    return struct {
        const Self = @This();
        const Reaper = teardown.Reaper(reaper_capacity);
        const Inbox = inbound.Inbox(receive_capacity);
        phase: Phase = .uninitialized,
        session: Session = undefined,
        inbox: Inbox = .{},
        outbox: outbound.Outbox(send_capacity) = undefined,
        reaper: *Reaper = undefined,
        ticket: ?Reaper.Ticket = null,
        provider: ?Provider = null,
        finalizer_submitted: bool = false,
        quiesced: bool = false,
        finalized_task: ?teardown.Task = null,
        held: ?Inbox.Lease = null,
        last_ns: u64 = 0,
        last_tick: ?u64 = null,
        grace_started: ?u64 = null,
        flush_expired: bool = false,
        open_pending: bool = false,
        open_delivered: bool = false,
        close_pending: bool = false,
        failure_pending: bool = false,
        remaining_frames: usize = 0,
        remaining_bytes: usize = 0,
        stats: Stats = .{},

        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, reaper: *Reaper, id: Session.Id, reliable: []u8, unreliable: []u8, config: Config, now_ns: u64) !void {
            if (self.phase != .uninitialized) return error.AlreadyInitialized;
            if (buffer.overlaps(reliable, std.mem.asBytes(self)) or buffer.overlaps(unreliable, std.mem.asBytes(self))) return error.AliasedStorage;
            const session = try Session.init(id, reliable, unreliable, config.receive, now_ns, config.negotiation_timeout_ns);
            const outbox = try outbound.Outbox(send_capacity).init(id, config.outgoing);
            const ticket = try reaper.reserve(id);
            errdefer reaper.cancelReservation(ticket) catch unreachable;
            try self.inbox.init(io, allocator, id, .{ .frame_bytes = config.receive.frame_bytes, .payload_bytes = config.incoming_bytes });
            self.session = session;
            self.outbox = outbox;
            self.reaper = reaper;
            self.ticket = ticket;
            self.last_ns = now_ns;
            self.phase = .reserved;
        }

        fn identity(self: *const Self, id: Session.Id) error{ NotInitialized, StaleSession }!void {
            if (self.phase == .uninitialized) return error.NotInitialized;
            if (!std.meta.eql(self.session.id, id)) return error.StaleSession;
        }

        pub fn attach(self: *Self, id: Session.Id, pending: *?Provider) !void {
            try self.identity(id);
            if (self.phase != .reserved) return error.NotReserved;
            if (buffer.overlaps(std.mem.asBytes(pending), std.mem.asBytes(self))) return error.AliasedProvider;
            const provider = pending.* orelse return error.EmptyTransfer;
            if (!std.meta.eql(provider.sink.session_id, id) or !std.meta.eql(provider.finalizer.session, id)) return error.WrongProvider;
            self.provider = provider;
            pending.* = null;
            self.phase = .negotiating;
        }

        pub fn channelOpened(self: *Self, id: Session.Id, channel: framing.Channel, options: Session.ChannelOptions, now_ns: u64) !void {
            try self.identity(id);
            if (self.phase != .negotiating and self.phase != .open) return error.NotNegotiating;
            if (now_ns < self.last_ns) return error.ClockWentBackwards;
            self.session.channelOpened(id, channel, options, now_ns) catch |err| {
                if (self.session.state == .closed) try self.forceClose(id, self.session.close_reason.?);
                return err;
            };
            self.last_ns = now_ns;
            if (self.session.state == .open) {
                self.phase = .open;
                self.open_pending = true;
            }
        }

        /// The provider may lower a frame ceiling during negotiation, before
        /// any application send is admitted. Existing policy ceilings never grow.
        pub fn limitSendFrame(self: *Self, id: Session.Id, channel: framing.Channel, maximum: usize) !usize {
            try self.identity(id);
            if (self.phase != .negotiating) return error.NotNegotiating;
            if (maximum < 2) return error.InvalidLimits;
            if (self.outbox.outstanding != 0) return error.PendingSends;
            const limits = &self.outbox.config.limits[@backingInt(channel)];
            limits.frame_bytes = @min(limits.frame_bytes, maximum);
            return limits.frame_bytes;
        }

        fn sendable(self: *Self, id: Session.Id) !void {
            try self.identity(id);
            if (self.phase == .draining) return error.Draining;
            if (self.phase != .open) return error.NotOpen;
        }

        pub fn sendOwned(self: *Self, id: Session.Id, channel: framing.Channel, pending: *?OwnedBytes) !outbound.Ticket {
            try self.sendable(id);
            if (buffer.overlaps(std.mem.asBytes(pending), std.mem.asBytes(self))) return error.AliasedPayload;
            if (pending.*) |*payload| {
                if (buffer.overlaps(payload.bytes(), std.mem.asBytes(self))) return error.AliasedPayload;
            }
            return self.outbox.enqueueOwned(&self.session, channel, pending);
        }

        pub fn sendCopy(self: *Self, allocator: std.mem.Allocator, id: Session.Id, channel: framing.Channel, bytes: []const u8) !outbound.Ticket {
            try self.sendable(id);
            return self.outbox.enqueueCopy(allocator, &self.session, channel, bytes);
        }

        /// Starts a flush on the next owner tick. Repeated requests never extend
        /// its deadline. No new application sends are admitted while draining.
        pub fn disconnect(self: *Self, id: Session.Id) !void {
            try self.identity(id);
            if (self.phase == .open) {
                self.phase = .draining;
            } else if (self.phase == .reserved or self.phase == .negotiating) try self.forceClose(id, .requested);
        }

        fn scheduleFinalizer(self: *Self) !void {
            if (self.finalizer_submitted or self.quiesced) return;
            if (self.provider) |provider| {
                var task: ?teardown.Task = provider.finalizer;
                try self.reaper.submit(self.ticket.?, &task);
                self.finalizer_submitted = true;
            } else {
                try self.reaper.cancelReservation(self.ticket.?);
                self.ticket = null;
                self.quiesced = true;
            }
        }

        pub fn forceClose(self: *Self, id: Session.Id, reason: Session.CloseReason) !void {
            try self.identity(id);
            if (self.phase == .retired) return;
            if (self.phase != .closing) {
                try self.session.close(id, reason);
                try self.outbox.shutdown(&self.session);
                try self.inbox.stop(id, .requested);
                if (self.held) |*lease| lease.deinit();
                self.held = null;
                self.open_pending = false;
                self.close_pending = self.open_delivered;
                self.phase = .closing;
            }
            try self.scheduleFinalizer();
        }

        fn stopped(self: *Self, reason: inbound.StopReason) !void {
            if (self.phase == .draining and reason == .transport_closed) {
                try self.forceClose(self.session.id, .requested);
            } else {
                _ = try self.inbox.applyStop(&self.session);
                try self.forceClose(self.session.id, self.session.close_reason.?);
            }
        }

        fn observe(self: *Self) !void {
            self.stats.drain_completions += self.outbox.observeDrains(&self.session, self.provider.?.sink) catch |err| switch (err) {
                error.ProviderClosed, error.ProviderFailed => {
                    try self.forceClose(self.session.id, self.session.close_reason.?);
                    return;
                },
                else => return err,
            };
        }

        fn nativeBuffer(self: *Self) !?[2]u64 {
            var amounts: [2]u64 = undefined;
            for (&amounts, 0..) |*amount, index| {
                amount.* = self.provider.?.sink.bufferedAmount(@fromBackingInt(@intCast(index))) catch |err| {
                    try self.forceClose(self.session.id, if (err == error.Closed and self.phase == .draining) .requested else if (err == error.Closed) .transport_closed else .outbound_failure);
                    return null;
                };
            }
            return amounts;
        }

        fn flushed(self: *Self, amounts: [2]u64) bool {
            return amounts[0] == 0 and amounts[1] == 0 and
                self.outbox.messages[0].count + self.outbox.messages[1].count + self.outbox.receipts[0].count + self.outbox.receipts[1].count == 0;
        }

        /// One call per increasing owner tick. Clock/ticket checks precede work.
        /// Receipt/control observations use at most six queries and 2*send_capacity
        /// scalar completions in addition to the explicit sender budget.
        pub fn beginTick(self: *Self, id: Session.Id, tick: u64, now_ns: u64, scratch: []u8, budget: Budget) !void {
            try self.identity(id);
            if (now_ns < self.last_ns) return error.ClockWentBackwards;
            if (self.last_tick) |last| {
                if (tick <= last) return error.StaleTick;
            }
            if (buffer.overlaps(scratch, std.mem.asBytes(self))) return error.AliasedScratch;
            if ((self.phase == .open or self.phase == .draining) and budget.send.steps != 0) try self.outbox.checkScratch(&self.session, scratch);
            self.last_ns = now_ns;
            self.last_tick = tick;
            self.stats = .{};
            self.remaining_frames = budget.receive_frames;
            self.remaining_bytes = budget.receive_bytes;
            if (self.phase == .retired) return;
            if (self.phase == .closing) {
                try self.scheduleFinalizer();
                _ = try self.inbox.discard(budget.discard_frames);
                return;
            }
            if (self.phase == .open or self.phase == .draining) try self.observe();
            if (self.phase == .closing) return;
            if ((try self.inbox.status()).reason) |reason| {
                try self.stopped(reason);
                return;
            }
            self.session.poll(now_ns) catch |err| {
                if (self.session.state != .closed) return err;
                try self.forceClose(id, self.session.close_reason.?);
                return;
            };
            if (self.phase != .open and self.phase != .draining) return;
            if (self.phase == .draining) {
                const start = self.grace_started orelse now_ns;
                self.grace_started = start;
                if (now_ns - start >= flush_timeout_ns) {
                    const amounts = (try self.nativeBuffer()) orelse return;
                    self.flush_expired = !self.flushed(amounts);
                    try self.forceClose(id, .requested);
                    return;
                }
            }
            self.stats.sent = self.outbox.pump(&self.session, self.provider.?.sink, scratch, budget.send) catch |err| switch (err) {
                error.ProviderClosed, error.ProviderFailed => {
                    try self.forceClose(id, self.session.close_reason.?);
                    return;
                },
                else => return err,
            };
            if (self.phase == .draining) {
                try self.observe();
                if (self.phase == .closing) return;
            }
            const amounts = (try self.nativeBuffer()) orelse return;
            if (self.phase == .draining) {
                if (self.flushed(amounts)) try self.forceClose(id, .requested);
            } else if (amounts[0] > self.outbox.config.buffered_bytes or amounts[1] > self.outbox.config.buffered_bytes - amounts[0]) try self.forceClose(id, .outbound_failure);
        }

        fn notification(self: *Self) !?Event {
            if (self.open_pending) {
                self.open_pending = false;
                self.open_delivered = true;
                return .{ .opened = self.session.id };
            }
            if (self.outbox.takeCompletion()) |completion| return .{ .sent = completion };
            if (self.close_pending) {
                self.close_pending = false;
                return .{ .closed = .{ .session = self.session.id, .reason = self.session.close_reason.?, .flush_expired = self.flush_expired } };
            }
            if (self.failure_pending) {
                self.failure_pending = false;
                return .{ .cleanup_failed = self.session.id };
            }
            if (self.phase == .closing and self.quiesced and (try self.inbox.status()).outstanding == 0) {
                self.phase = .retired;
                const task = self.finalized_task;
                self.finalized_task = null;
                self.provider = null;
                return .{ .finalized = .{ .session = self.session.id, .task = task } };
            }
            return null;
        }

        /// Control delivery never reads an application frame. Keep consuming
        /// control events when application packet admission is paused.
        pub fn nextControlEvent(self: *Self, id: Session.Id) !?Event {
            try self.identity(id);
            if (self.phase == .retired) return null;
            return self.notification();
        }

        /// Pull only when the application can accept another event. Message
        /// bytes borrow receiver storage until the next connection mutation.
        /// At most 64 messages and the supplied frame/byte budget per owner tick.
        pub fn nextEvent(self: *Self, id: Session.Id) !?Event {
            try self.identity(id);
            if (self.phase == .retired) return null;
            if (try self.notification()) |event| return event;
            if (self.phase != .open) return null;
            while (self.remaining_frames != 0 and self.stats.packets < packet_limit) {
                if (self.held == null) self.held = self.inbox.receive() catch |err| switch (err) {
                    error.Closed => {
                        try self.stopped((try self.inbox.status()).reason.?);
                        return self.notification();
                    },
                    else => return err,
                };
                const lease = if (self.held) |*lease| lease else return null;
                const length = lease.bytes().len;
                if (length > self.remaining_bytes) {
                    self.stats.receive_limited = true;
                    return null;
                }
                self.remaining_frames -= 1;
                self.remaining_bytes -= length;
                self.stats.frames += 1;
                self.stats.bytes += length;
                const channel = lease.channel;
                const complete = lease.accept(&self.session, self.last_ns) catch |err| {
                    if (self.session.state != .closed) return err;
                    try self.forceClose(id, self.session.close_reason.?);
                    return self.notification();
                };
                lease.deinit();
                self.held = null;
                if (complete) |payload| {
                    self.stats.packets += 1;
                    return .{ .message = .{ .session = id, .channel = channel, .payload = payload } };
                }
            }
            self.stats.receive_limited = true;
            return null;
        }

        /// The shared reaper's owner routes each collected result to its scoped
        /// connection. No provider memory is returned before successful cleanup.
        pub fn finalized(self: *Self, completion: Reaper.Completion) !void {
            try self.identity(completion.session);
            if (self.phase != .closing or self.ticket == null or !std.meta.eql(self.ticket.?, completion.ticket)) return error.WrongFinalizer;
            if (completion.outcome == .failed) {
                if (try self.reaper.phase(completion.ticket) != .failed) return error.WrongFinalizer;
                self.failure_pending = true;
                return;
            }
            self.finalized_task = try self.reaper.takeFinalized(completion.ticket);
            self.ticket = null;
            self.quiesced = true;
        }

        pub fn retryFinalizer(self: *Self, id: Session.Id) !void {
            try self.identity(id);
            if (self.phase != .closing or self.ticket == null) return error.NotFailed;
            if (self.failure_pending) return error.UnreportedFailure;
            try self.reaper.retry(self.ticket.?);
        }

        pub fn discardClosed(self: *Self, id: Session.Id, limit: usize) !usize {
            try self.identity(id);
            if (self.phase != .closing) return error.NotClosing;
            return self.inbox.discard(limit);
        }

        pub fn deinit(self: *Self) error{NotRetired}!void {
            if (self.phase != .retired) return error.NotRetired;
            self.inbox.deinit();
            self.outbox.deinit();
            self.* = undefined;
        }
    };
}
