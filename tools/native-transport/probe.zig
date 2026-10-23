const std = @import("std");
const Mailbox = @import("shulvyr").Mailbox;
const framing = @import("shulvyr").framing;
const Session = @import("shulvyr").TransportSession;
const Connection = @import("shulvyr").Connection(8, 16, 4);
const connection = @import("shulvyr").connection;
const FrameSink = @import("shulvyr").FrameSink;
const Inbox = @import("shulvyr").Inbox(16);
const Reaper = @import("shulvyr").Reaper(4);
const Task = @import("shulvyr").teardown.Task;
const Runtime = @import("shulvyr").Runtime;
const c = @import("rtc");

// This development probe owns all contexts until rtcCleanup returns. It uses
// loopback ICE only and never prints SDP, ICE credentials or native log text.
const ChannelContext = struct { parent: *Context, channel: framing.Channel, id: c_int = -1 };
const Context = struct {
    io: std.Io,
    session_id: Session.Id = .{ .owner = 1, .index = 0, .generation = 1 },
    events: Mailbox(c_int, 4) = .{},
    inbox: *Inbox = undefined,
    inbox_storage: Inbox = .{},
    channel_contexts: [2]ChannelContext = undefined,
    failed: std.atomic.Value(bool) = .init(false),
    gathering_done: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    callbacks: std.atomic.Value(u32) = .init(0),
    hold_entered: std.atomic.Value(bool) = .init(false),
    hold_release: std.atomic.Value(bool) = .init(false),
    rejected_channels: std.atomic.Value(u32) = .init(0),
    last_rejected: std.atomic.Value(c_int) = .init(-1),

    fn init(self: *Context, allocator: std.mem.Allocator, external: ?*Inbox) !void {
        try self.events.init();
        self.inbox = external orelse &self.inbox_storage;
        if (external == null) try self.inbox.init(self.io, allocator, self.session_id, .{ .frame_bytes = 17, .payload_bytes = 16 * 17 });
        for (&self.channel_contexts, 0..) |*binding, channel| binding.* = .{ .parent = self, .channel = @fromBackingInt(@intCast(channel)) };
    }

    fn pushChannel(self: *Context, dc: c_int) void {
        var pending: ?c_int = dc;
        self.events.send(self.io, &pending) catch {
            self.failed.store(true, .release);
            self.inbox.stop(self.session_id, .delivery_failure) catch {};
            // No callbacks were installed on this new handle. Retire it here
            // rather than lose ownership when the discovery queue is full.
            if (c.rtcDeleteDataChannel(dc) >= 0) self.last_rejected.store(dc, .release);
            _ = self.rejected_channels.fetchAdd(1, .release);
        };
    }

    fn from(raw: ?*anyopaque) *Context {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn gathering(_: c_int, state: c.rtcGatheringState, raw: ?*anyopaque) callconv(.c) void {
    const context = Context.from(raw);
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    if (state == c.RTC_GATHERING_COMPLETE) context.gathering_done.store(true, .release);
}

fn incoming(_: c_int, dc: c_int, raw: ?*anyopaque) callconv(.c) void {
    const context = Context.from(raw);
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    // Channel handles remain owned even during shutdown. The owner drains them
    // after unregistering this callback, before destroying the peer.
    context.pushChannel(dc);
}

fn message(id: c_int, bytes: [*c]const u8, size: c_int, raw: ?*anyopaque) callconv(.c) void {
    const binding: *ChannelContext = @ptrCast(@alignCast(raw.?));
    const context = binding.parent;
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    if (context.closing.load(.acquire)) return;
    if (id < 0 or id != binding.id) {
        context.failed.store(true, .release);
        context.inbox.stop(context.session_id, .delivery_failure) catch {};
        return;
    }
    if (size < 2 or size > 17 or bytes == null) {
        context.inbox.stop(context.session_id, .invalid_frame) catch {
            context.failed.store(true, .release);
        };
        return;
    }
    // Admission failures are sticky and observed by the owner outside the queue.
    context.inbox.post(context.session_id, binding.channel, bytes[0..@intCast(size)]) catch |err| switch (err) {
        error.Closed, error.QueueFull, error.PayloadBudgetExceeded, error.InvalidFrame, error.OutOfMemory => {},
        else => context.failed.store(true, .release),
    };
}

fn closed(id: c_int, raw: ?*anyopaque) callconv(.c) void {
    const binding: *ChannelContext = @ptrCast(@alignCast(raw.?));
    const context = binding.parent;
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    if (context.closing.load(.acquire)) return;
    if (id < 0 or id != binding.id) {
        context.failed.store(true, .release);
        context.inbox.stop(context.session_id, .delivery_failure) catch {};
        return;
    }
    context.inbox.stop(context.session_id, .transport_closed) catch {
        context.failed.store(true, .release);
    };
}

fn blockedMessage(_: c_int, _: [*c]const u8, _: c_int, raw: ?*anyopaque) callconv(.c) void {
    const binding: *ChannelContext = @ptrCast(@alignCast(raw.?));
    const context = binding.parent;
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    context.hold_entered.store(true, .release);
    const start = std.Io.Clock.awake.now(context.io);
    while (!context.hold_release.load(.acquire)) {
        deadline(context.io, start) catch {
            context.failed.store(true, .release);
            return;
        };
        std.Thread.yield() catch {
            context.failed.store(true, .release);
            return;
        };
    }
}

fn check(result: c_int) !void {
    if (result < 0) return error.NativeCallFailed;
}

fn expect(ok: bool) !void {
    if (!ok) return error.ProbeAssertionFailed;
}

fn deadline(io: std.Io, start: std.Io.Timestamp) !void {
    if (start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() > 15 * std.time.ns_per_s)
        return error.ProbeTimeout;
}

fn pause(io: std.Io, start: std.Io.Timestamp) !void {
    try deadline(io, start);
    try std.Io.sleep(io, .fromMilliseconds(1), .awake);
}

const labels = [_][:0]const u8{ "ReliableDataChannel", "UnreliableDataChannel" };
const NativeSink = struct {
    pair: *Pair,
    peer: usize,

    fn buffered(raw: *anyopaque, channel: framing.Channel) FrameSink.Error!u64 {
        const self: *NativeSink = @ptrCast(@alignCast(raw));
        const dc = self.pair.channels[self.peer][@backingInt(channel)];
        if (dc < 0) return error.Closed;
        const amount = c.rtcGetBufferedAmount(dc);
        if (amount < 0) return error.Failed;
        return @intCast(amount);
    }

    fn send(raw: *anyopaque, channel: framing.Channel, frame: []const u8) FrameSink.Error!FrameSink.Admission {
        const self: *NativeSink = @ptrCast(@alignCast(raw));
        const dc = self.pair.channels[self.peer][@backingInt(channel)];
        if (dc < 0 or !c.rtcIsOpen(dc)) return error.Closed;
        if (c.rtcSendMessage(dc, frame.ptr, @intCast(frame.len)) < 0) return error.Failed;
        return .accepted;
    }

    fn sink(self: *NativeSink) FrameSink {
        return .{ .session_id = self.pair.contexts[self.peer].session_id, .context = self, .buffered = buffered, .send = send };
    }
};
var finalized_peers: u32 = 0;
var owner_ticks: u32 = 0;
var graceful_closes: u32 = 0;

const NativePeer = struct {
    context: *Context,
    peer: c_int = -1,
    channels: [2]c_int = @splat(-1),
    extra: [5]c_int = @splat(-1),
    orphan: ?c_int = null,
    entered: std.atomic.Value(bool) = .init(false),

    fn deleteChannel(dc: *c_int) error{Failed}!void {
        if (dc.* < 0) return;
        // Deletion itself must provide the channel callback barrier.
        if (c.rtcDeleteDataChannel(dc.*) < 0) return error.Failed;
        dc.* = -1;
    }

    fn finalize(raw: *anyopaque) error{Failed}!void {
        const self: *NativePeer = @ptrCast(@alignCast(raw));
        self.context.closing.store(true, .release);
        self.entered.store(true, .release);
        if (self.peer >= 0) {
            if (c.rtcSetDataChannelCallback(self.peer, null) < 0) return error.Failed;
            if (c.rtcSetGatheringStateChangeCallback(self.peer, null) < 0) return error.Failed;
        }
        if (self.context.events.queue != null) {
            while (true) {
                if (self.orphan == null) self.orphan = self.context.events.receive(self.context.io) catch return error.Failed;
                if (self.orphan) |dc| {
                    if (c.rtcDeleteDataChannel(dc) < 0) return error.Failed;
                    self.orphan = null;
                } else break;
            }
        }
        for (&self.channels) |*dc| try deleteChannel(dc);
        for (&self.extra) |*dc| try deleteChannel(dc);
        if (self.peer >= 0) {
            if (c.rtcDeletePeerConnection(self.peer) < 0) return error.Failed;
            self.peer = -1;
        }
        if (self.context.callbacks.load(.acquire) != 0) return error.Failed;
    }
};

const Pair = struct {
    reaper: *Reaper,
    native: [2]NativePeer = undefined,
    extra: [2][5]c_int = .{ @splat(-1), @splat(-1) },
    contexts: [2]Context,
    peers: [2]c_int = .{ -1, -1 },
    channels: [2][2]c_int = .{ .{ -1, -1 }, .{ -1, -1 } },
    received: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    seen: [2][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    connections: [2]Connection = .{ .{}, .{} },
    connection_ready: [2]bool = .{ false, false },
    closed_seen: [2]bool = .{ false, false },
    epoch: u64 = 0,
    sinks: [2]NativeSink = undefined,
    receipt_count: [2]u8 = .{ 0, 0 },
    receipt_seen: [2]u64 = .{ 0, 0 },
    reliable_storage: [2][64]u8 = undefined,
    unreliable_storage: [2][16]u8 = undefined,
    framed_messages: usize = 0,
    clock_start: std.Io.Timestamp,
    cycle: u8,

    fn init(self: *Pair, allocator: std.mem.Allocator) !void {
        try check(c.rtcSetThreadPoolSize(4));
        var config = std.mem.zeroes(c.rtcConfiguration);
        config.bindAddress = "127.0.0.1";
        config.disableAutoNegotiation = true;
        config.maxMessageSize = 1024;
        for (&self.contexts, 0..) |*context, i| {
            context.session_id = .{ .owner = 1, .index = @intCast(i), .generation = @as(u64, self.cycle) + 1 };
            self.native[i] = .{ .context = context };
            try self.connections[i].init(allocator, context.io, self.reaper, context.session_id, &self.reliable_storage[i], &self.unreliable_storage[i], .{
                .receive = .{ .frame_bytes = 17, .message_bytes = 64 },
                .incoming_bytes = 16 * 17,
                .outgoing = .{
                    .limits = .{ .{ .frame_bytes = 7, .message_bytes = 64 }, .{ .frame_bytes = 17, .message_bytes = 64 } },
                    .payload_bytes = 64,
                    .buffered_bytes = 1024,
                },
                .negotiation_timeout_ns = 15 * std.time.ns_per_s,
            }, self.now());
            self.connection_ready[i] = true;
            try context.init(allocator, &self.connections[i].inbox);
            self.sinks[i] = .{ .pair = self, .peer = i };
            var provider: ?connection.Provider = .{ .sink = self.sinks[i].sink(), .finalizer = .{ .session = context.session_id, .context = &self.native[i], .finalize = NativePeer.finalize } };
            try self.connections[i].attach(context.session_id, &provider);
            self.peers[i] = c.rtcCreatePeerConnection(&config);
            self.native[i].peer = self.peers[i];
            try check(self.peers[i]);
            c.rtcSetUserPointer(self.peers[i], context);
            try check(c.rtcSetGatheringStateChangeCallback(self.peers[i], gathering));
            try check(c.rtcSetDataChannelCallback(self.peers[i], incoming));
        }
        for (labels, 0..) |label, i| {
            var options = std.mem.zeroes(c.rtcDataChannelInit);
            options.reliability.unordered = i == 1;
            options.reliability.unreliable = i == 1;
            self.channels[0][i] = c.rtcCreateDataChannelEx(self.peers[0], label, &options);
            self.native[0].channels[i] = self.channels[0][i];
            try check(self.channels[0][i]);
            self.contexts[0].channel_contexts[i].id = self.channels[0][i];
            c.rtcSetUserPointer(self.channels[0][i], &self.contexts[0].channel_contexts[i]);
            try check(c.rtcSetMessageCallback(self.channels[0][i], message));
            try check(c.rtcSetClosedCallback(self.channels[0][i], closed));
        }
    }

    fn beginClose(self: *Pair, peer: usize) !void {
        if (self.connection_ready[peer]) try self.connections[peer].forceClose(self.contexts[peer].session_id, .requested);
    }

    fn collectFinalizers(self: *Pair) !bool {
        const completion = (try self.reaper.collect()) orelse return false;
        for (&self.connections, self.connection_ready) |*node, ready| {
            if (!ready or !std.meta.eql(node.session.id, completion.session)) continue;
            try node.finalized(completion);
            return true;
        }
        return error.UnexpectedFinalizerResult;
    }

    fn drainEvents(self: *Pair, peer: usize) !void {
        const context = &self.contexts[peer];
        while (try self.connections[peer].nextEvent(context.session_id)) |event| switch (event) {
            .opened => {},
            .message => |received| {
                const bytes = received.payload;
                const channel = @backingInt(received.channel);
                try expect(bytes.len == 16 and bytes[2] == channel);
                const sequence = bytes[3];
                try expect(sequence < 32);
                try expect(std.mem.eql(u8, bytes, &payload(self.cycle, @intCast(1 - peer), channel, sequence)));
                const bit = @as(u32, 1) << @as(u5, @intCast(sequence));
                try expect(self.seen[peer][channel] & bit == 0);
                if (channel == 0) try expect(sequence == self.received[peer][channel]);
                self.seen[peer][channel] |= bit;
                self.received[peer][channel] += 1;
            },
            .sent => |completion| {
                try expect(!self.closed_seen[peer]);
                const sequence = completion.ticket.sequence;
                try expect(sequence >= 1 and sequence <= 64);
                try expect(std.meta.eql(completion.ticket.session, context.session_id));
                try expect(completion.outcome == .drained and completion.payload_bytes == 16);
                const fragments: u16 = if (completion.channel == .reliable) 3 else 1;
                try expect(completion.frames == fragments and completion.wire_bytes == 16 + fragments);
                const bit = @as(u64, 1) << @as(u6, @intCast(sequence - 1));
                try expect(self.receipt_seen[peer] & bit == 0);
                self.receipt_seen[peer] |= bit;
                self.receipt_count[peer] += 1;
            },
            .closed => self.closed_seen[peer] = true,
            .cleanup_failed => return error.NativeCleanupFailed,
            .finalized => |done| {
                if (done.task) |task| {
                    try expect(task.context == @as(*anyopaque, &self.native[peer]));
                    try expect(self.native[peer].peer == -1 and context.callbacks.load(.acquire) == 0);
                    finalized_peers += 1;
                }
                self.peers[peer] = -1;
                self.channels[peer] = @splat(-1);
                self.extra[peer] = @splat(-1);
            },
        };
    }

    fn awaitPeer(self: *Pair, peer: usize) !void {
        if (!self.connection_ready[peer]) return;
        const start = std.Io.Clock.awake.now(self.contexts[peer].io);
        while (self.connections[peer].phase != .retired) {
            _ = try self.collectFinalizers();
            _ = try self.connections[peer].discardClosed(self.contexts[peer].session_id, 16);
            try self.drainEvents(peer);
            if (self.connections[peer].phase != .retired) try pause(self.contexts[peer].io, start);
        }
    }

    fn deinit(self: *Pair) !void {
        for (&self.contexts) |*context| context.hold_release.store(true, .release);
        for (0..2) |peer| try self.beginClose(peer);
        for (0..2) |peer| try self.awaitPeer(peer);
        // Global cleanup is a management operation after per-peer barriers.
        c.rtcCleanup();
        for (&self.contexts, 0..) |*context, peer| {
            context.events.close(context.io);
            try expect(context.callbacks.load(.acquire) == 0);
            if (self.connection_ready[peer]) try self.connections[peer].deinit();
        }
    }

    fn drain(self: *Pair) !void {
        self.epoch += 1;
        for (&self.contexts, 0..) |*context, peer| {
            var discoveries: usize = 0;
            if (self.connections[peer].phase != .closing and self.connections[peer].phase != .retired) {
                while (discoveries < 16) : (discoveries += 1) {
                    const dc = (try context.events.receive(context.io)) orelse break;
                    // Take ownership before validation, so failed probes clean up.
                    var slot: ?usize = null;
                    for (self.channels[peer], 0..) |known, i| {
                        if (known < 0) {
                            slot = i;
                            break;
                        }
                    }
                    if (slot == null) {
                        try check(c.rtcDeleteDataChannel(dc));
                        return error.ExtraChannel;
                    }
                    self.channels[peer][slot.?] = dc;
                    self.native[peer].channels[slot.?] = dc;
                    var label: [64]u8 = undefined;
                    const length = c.rtcGetDataChannelLabel(dc, &label, label.len);
                    try check(length);
                    try expect(length > 0 and length <= label.len and label[@intCast(length - 1)] == 0);
                    const name = label[0..@intCast(length - 1)];
                    var index: ?usize = null;
                    for (labels, 0..) |expected, i| {
                        if (std.mem.eql(u8, name, expected)) index = i;
                    }
                    try expect(peer == 1 and index != null);
                    if (index.? != slot.?) {
                        try expect(self.channels[peer][index.?] < 0);
                        self.channels[peer][index.?] = dc;
                        self.channels[peer][slot.?] = -1;
                        self.native[peer].channels[index.?] = dc;
                        self.native[peer].channels[slot.?] = -1;
                    }
                    var protocol: [1]u8 = undefined;
                    try expect(c.rtcGetDataChannelProtocol(dc, &protocol, protocol.len) == 1 and protocol[0] == 0);
                    var reliability: c.rtcReliability = undefined;
                    try check(c.rtcGetDataChannelReliability(dc, &reliability));
                    try expect(reliability.unordered == (index.? == 1));
                    try expect(reliability.unreliable == (index.? == 1));
                    try expect(reliability.maxRetransmits == 0 and reliability.maxPacketLifeTime == 0);
                    context.channel_contexts[index.?].id = dc;
                    c.rtcSetUserPointer(dc, &context.channel_contexts[index.?]);
                    try check(c.rtcSetMessageCallback(dc, message));
                    try check(c.rtcSetClosedCallback(dc, closed));
                }
            }
            var scratch: [17]u8 = undefined;
            try self.connections[peer].beginTick(context.session_id, self.epoch, self.now(), &scratch, .{
                .send = .{ .steps = 1, .wire_bytes = 17 },
                .receive_frames = 16 - discoveries,
                .receive_bytes = 16 * 17,
                .discard_frames = 16,
            });
            @memset(&scratch, 0);
            try self.drainEvents(peer);
            self.framed_messages += self.connections[peer].stats.frames;
            if (context.failed.load(.acquire)) return error.CallbackFailed;
        }
    }

    fn now(self: *const Pair) u64 {
        return @intCast(self.clock_start.durationTo(std.Io.Clock.awake.now(self.contexts[0].io)).toNanoseconds());
    }

    fn openChannels(self: *Pair) !bool {
        var all_open = true;
        for (self.channels, 0..) |channels, peer| for (channels, 0..) |dc, channel| {
            if (dc < 0 or !c.rtcIsOpen(dc)) {
                all_open = false;
                continue;
            }
            if (!self.connections[peer].session.opened[channel]) {
                var reliability: c.rtcReliability = undefined;
                try check(c.rtcGetDataChannelReliability(dc, &reliability));
                const options: Session.ChannelOptions = .{
                    .ordered = !reliability.unordered,
                    .max_retransmits = if (reliability.unreliable and reliability.maxPacketLifeTime == 0) reliability.maxRetransmits else null,
                    .max_packet_lifetime_ms = if (reliability.unreliable and reliability.maxPacketLifeTime > 0) reliability.maxPacketLifeTime else null,
                };
                try self.connections[peer].channelOpened(self.contexts[peer].session_id, @fromBackingInt(@intCast(channel)), options, self.now());
            }
        };
        return all_open;
    }

    fn exchangeDescription(self: *Pair, source: usize, kind: [:0]const u8) !void {
        const context = &self.contexts[source];
        try check(c.rtcSetLocalDescription(self.peers[source], kind));
        const start = std.Io.Clock.awake.now(context.io);
        while (!context.gathering_done.load(.acquire)) try pause(context.io, start);
        var description: [16 * 1024]u8 = undefined;
        defer @memset(&description, 0);
        const count = c.rtcGetLocalDescription(self.peers[source], &description, description.len);
        try check(count);
        try expect(count > 0 and count <= description.len and description[@intCast(count - 1)] == 0);
        const text = description[0..@intCast(count - 1)];
        try expect(std.mem.indexOf(u8, text, "a=candidate:") != null);
        try expect(std.mem.indexOf(u8, text, "127.0.0.1") != null);
        try expect(std.mem.indexOf(u8, text, " TCP ") == null);
        try expect(std.mem.indexOf(u8, text, "a=fingerprint:") != null);
        try check(c.rtcSetRemoteDescription(self.peers[1 - source], &description, kind));
    }
};

fn payload(cycle: u8, sender: u8, channel: u8, sequence: u8) [16]u8 {
    return .{ cycle, sender, channel, sequence, 0, 255, 0, 128, 1, 2, 3, 4, 5, 6, 7, 8 };
}

fn runCycle(io: std.Io, allocator: std.mem.Allocator, reaper: *Reaper, cycle: u8) !void {
    var pair: Pair = .{ .reaper = reaper, .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = cycle, .clock_start = std.Io.Clock.awake.now(io) };
    defer pair.deinit() catch @panic("Native cleanup failed");
    try pair.init(allocator);
    try pair.exchangeDescription(0, "offer");
    try pair.exchangeDescription(1, "answer");
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    for (0..32) |sequence| {
        for (0..2) |sender| for (0..2) |channel| {
            const bytes = payload(cycle, @intCast(sender), @intCast(channel), @intCast(sequence));
            _ = try pair.connections[sender].sendCopy(allocator, pair.contexts[sender].session_id, @fromBackingInt(@intCast(channel)), &bytes);
        };
        const sent = std.Io.Clock.awake.now(io);
        while (true) {
            try pair.drain();
            var complete = true;
            for (pair.received) |counts| for (counts) |count| {
                if (count != sequence + 1) complete = false;
            };
            for (pair.receipt_count) |count| {
                if (count != 2 * (sequence + 1)) complete = false;
            }
            if (complete) break;
            try pause(io, sent);
        }
    }
    try expect(pair.framed_messages == 256);
    // Cancel a real partial reliable message before its final fragment arrives.
    const partial = [_]u8{ 1, 171, 205 };
    try check(c.rtcSendMessage(pair.channels[0][0], &partial, partial.len));
    const partial_start = std.Io.Clock.awake.now(io);
    while (pair.connections[1].session.receivers[0].used == 0) {
        try pair.drain();
        try pause(io, partial_start);
    }
    try expect(pair.connections[1].session.receivers[0].used == 2 and pair.framed_messages == 257);
    try pair.connections[1].session.close(pair.contexts[1].session_id, .requested);
    try expect(pair.connections[1].session.state == .closed and pair.connections[1].session.receivers[0].used == 0);
    // Verify the documented deletion barrier with an actual C++ callback held
    // on a native thread. Releasing it must not depend on the deleting thread.
    const context = &pair.contexts[1];
    const dc = pair.channels[1][0];
    try check(c.rtcSetMessageCallback(dc, blockedMessage));
    const bytes = payload(cycle, 0, 0, 0);
    var segmenter = try framing.Sender.init(.reliable, &bytes, .{ .frame_bytes = 17 });
    var scratch: [17]u8 = undefined;
    const frame = (try segmenter.write(&scratch)).?;
    try check(c.rtcSendMessage(pair.channels[0][0], frame.ptr, @intCast(frame.len)));
    try expect(segmenter.commit());
    const held_start = std.Io.Clock.awake.now(io);
    while (!context.hold_entered.load(.acquire)) try pause(io, held_start);
    try pair.beginClose(1);
    defer context.hold_release.store(true, .release);
    while (!pair.native[1].entered.load(.acquire)) try pause(io, held_start);
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try expect(!try pair.collectFinalizers());
    var runtime: Runtime = .{};
    try runtime.start(.{ .ticks = 4 });
    defer runtime.stop();
    for (0..3) |_| try runtime.tick();
    try expect(runtime.ticks == 3 and runtime.state == .running);
    owner_ticks += 3;
    try expect(!try pair.collectFinalizers());
    context.hold_release.store(true, .release);
    try pair.awaitPeer(1);
    try expect(context.callbacks.load(.acquire) == 0 and !context.failed.load(.acquire));
    const disconnect_start = std.Io.Clock.awake.now(io);
    while (pair.connections[0].session.state != .closed) {
        try pair.drain();
        try pause(io, disconnect_start);
    }
    try expect(pair.connections[0].session.close_reason == .transport_closed);
}

fn cancelGathering(io: std.Io, allocator: std.mem.Allocator, reaper: *Reaper) !void {
    for (0..16) |index| {
        var pair: Pair = .{ .reaper = reaper, .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = @intCast(index + 3), .clock_start = std.Io.Clock.awake.now(io) };
        defer pair.deinit() catch @panic("Native cancellation cleanup failed");
        try pair.init(allocator);
        try check(c.rtcSetLocalDescription(pair.peers[0], "offer"));
        // Do not wait for ICE or callbacks. Teardown must retain their contexts.
    }
}

fn gracefulDisconnect(io: std.Io, allocator: std.mem.Allocator, reaper: *Reaper) !void {
    var pair: Pair = .{ .reaper = reaper, .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = 21, .clock_start = std.Io.Clock.awake.now(io) };
    defer pair.deinit() catch @panic("Native graceful cleanup failed");
    try pair.init(allocator);
    try pair.exchangeDescription(0, "offer");
    try pair.exchangeDescription(1, "answer");
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    try pair.drain();
    const sender = &pair.connections[0];
    const id = pair.contexts[0].session_id;
    _ = try sender.sendCopy(allocator, id, .reliable, &payload(pair.cycle, 0, 0, 0));
    try sender.disconnect(id);
    const closing_start = std.Io.Clock.awake.now(io);
    while (sender.phase != .retired) {
        try pair.drain();
        while (try pair.collectFinalizers()) {}
        if (sender.phase != .retired) try pause(io, closing_start);
    }
    try expect(pair.receipt_count[0] == 1 and pair.closed_seen[0]);
    try expect(sender.session.close_reason == .requested and !sender.flush_expired);
    // Drain completion describes the local provider queue, not peer delivery.
    graceful_closes += 1;
}

fn cleanupTestContext(context: *Context) void {
    context.closing.store(true, .release);
    context.inbox.stop(context.session_id, .requested) catch unreachable;
    _ = context.inbox.discard(16) catch unreachable;
    context.inbox.deinit();
    context.events.close(context.io);
}

fn callbackBoundaries(io: std.Io, allocator: std.mem.Allocator) !void {
    var context: Context = .{ .io = io };
    try context.init(allocator, null);
    defer cleanupTestContext(&context);
    const binding = &context.channel_contexts[0];
    binding.id = 7;
    var bytes: [17]u8 = undefined;
    bytes[0] = 0;
    @memcpy(bytes[1..], &payload(1, 0, 0, 0));
    for (0..16) |_| message(7, &bytes, bytes.len, binding);
    @memset(&bytes, 42);
    // Stop survives a full queue and a later native close callback.
    message(7, &bytes, bytes.len, binding);
    closed(7, binding);
    try expect((try context.inbox.status()).reason == .queue_full);
    for (0..16) |_| {
        var lease = (try context.inbox.receive()).?;
        defer lease.deinit();
        try expect(lease.bytes().len == 17 and lease.bytes()[0] == 0);
        try expect(std.mem.eql(u8, lease.bytes()[1..], &payload(1, 0, 0, 0)));
    }
    try expect((try context.inbox.status()).outstanding == 0);
    for ([_]c_int{ -1, 17, 18, 0, 1 }, 0..) |size, index| {
        var invalid: Context = .{ .io = io };
        try invalid.init(allocator, null);
        defer cleanupTestContext(&invalid);
        invalid.channel_contexts[0].id = 7;
        message(7, if (index == 1) null else &bytes, size, &invalid.channel_contexts[0]);
        try expect((try invalid.inbox.status()).reason == .invalid_frame);
        try expect((try invalid.inbox.status()).outstanding == 0);
        try expect(invalid.callbacks.load(.acquire) == 0);
    }
    var wrong_id: Context = .{ .io = io };
    try wrong_id.init(allocator, null);
    defer cleanupTestContext(&wrong_id);
    wrong_id.channel_contexts[0].id = 7;
    message(8, &bytes, bytes.len, &wrong_id.channel_contexts[0]);
    try expect(wrong_id.failed.load(.acquire));
    try expect((try wrong_id.inbox.status()).reason == .delivery_failure);
    try expect((try wrong_id.inbox.status()).outstanding == 0);
}

fn incomingChannelOverflow(io: std.Io, allocator: std.mem.Allocator, reaper: *Reaper) !void {
    var pair: Pair = .{ .reaper = reaper, .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = 20, .clock_start = std.Io.Clock.awake.now(io) };
    defer pair.deinit() catch @panic("Native overflow cleanup failed");
    try pair.init(allocator);
    try pair.exchangeDescription(0, "offer");
    try pair.exchangeDescription(1, "answer");
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    for (&pair.extra[0], 0..) |*dc, index| {
        dc.* = c.rtcCreateDataChannel(pair.peers[0], "ExtraDataChannel");
        pair.native[0].extra[index] = dc.*;
        try check(dc.*);
    }
    const receiver = &pair.contexts[1];
    const overflow_start = std.Io.Clock.awake.now(io);
    while (receiver.rejected_channels.load(.acquire) == 0) try pause(io, overflow_start);
    try expect(receiver.rejected_channels.load(.acquire) == 1);
    const rejected = receiver.last_rejected.load(.acquire);
    try expect(rejected >= 0 and c.rtcGetDataChannelStream(rejected) < 0);
    pair.epoch += 1;
    var scratch: [17]u8 = undefined;
    try pair.connections[1].beginTick(receiver.session_id, pair.epoch, pair.now(), &scratch, .{ .send = .{ .steps = 0, .wire_bytes = 0 }, .receive_frames = 0, .receive_bytes = 0, .discard_frames = 16 });
    try expect(pair.connections[1].session.close_reason == .inbound_failure);
    try expect((try receiver.inbox.status()).outstanding == 0);
}

fn runChecks(io: std.Io, allocator: std.mem.Allocator) !void {
    try callbackBoundaries(io, allocator);
    var reaper: Reaper = .{};
    try reaper.init(allocator, io, 1);
    defer {
        reaper.requestStop() catch @panic("Reaper stop failed");
        reaper.join() catch @panic("Reaper still owns native contexts");
        reaper.deinit() catch @panic("Reaper deinit failed");
    }
    for (0..3) |cycle| runCycle(io, allocator, &reaper, @intCast(cycle)) catch |err| {
        std.debug.print("transport cycle {d} failed: {s}\n", .{ cycle, @errorName(err) });
        return err;
    };
    try cancelGathering(io, allocator, &reaper);
    try incomingChannelOverflow(io, allocator, &reaper);
    try gracefulDisconnect(io, allocator, &reaper);
    try expect(finalized_peers == 42 and owner_ticks == 9 and graceful_closes == 1);
}

pub fn main(init: std.process.Init) !u8 {
    c.rtcInitLogger(c.RTC_LOG_NONE, null);
    var memory: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .canary = 0x5368756c, .stack_trace_frames = 0 });
    var passed = true;
    runChecks(init.io, memory.allocator()) catch |err| {
        std.debug.print("native probe failed: {s}\n", .{@errorName(err)});
        passed = false;
    };
    const leaks = memory.deinitLog(false);
    if (leaks != 0) {
        std.debug.print("native probe leaked {d} Zig allocations\n", .{leaks});
        passed = false;
    }
    if (!passed) return 1;
    var buffer: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try output.interface.writeAll("{\"cycles\":3,\"binary_messages\":384,\"drained_receipts\":384,\"framed_messages\":771,\"cancelled_assemblies\":3,\"native_disconnects\":3,\"deletion_barriers\":3,\"cancelled_offers\":16,\"callback_boundary_checks\":7,\"incoming_channel_overflows\":1,\"zig_allocation_leaks\":0,\"finalized_peers\":42,\"owner_ticks_while_closing\":9,\"graceful_closes\":1}\n");
    try output.interface.flush();
    return 0;
}
