const std = @import("std");
const framing = @import("shulvyr").framing;
const Session = @import("shulvyr").TransportSession;
const Manager = @import("shulvyr").ConnectionManager(8, 16, 4);
const Connection = Manager.Connection;
const Runtime = @import("shulvyr").Runtime;
const webrtc = @import("webrtc");
const NativePeer = webrtc.Peer(16, 4);
const c = webrtc.native;

// Loopback development tooling. Never print SDP or ICE credentials.
const Blocker = struct {
    io: std.Io = undefined,
    callbacks: std.atomic.Value(u32) = .init(0),
    hold_entered: std.atomic.Value(bool) = .init(false),
    hold_release: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
};

fn blockedMessage(_: c_int, _: [*c]const u8, _: c_int, raw: ?*anyopaque) callconv(.c) void {
    const context: *Blocker = @ptrCast(@alignCast(raw.?));
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

var finalized_peers: u32 = 0;
var owner_ticks: u32 = 0;
var graceful_closes: u32 = 0;
var backpressure_checks: u32 = 0;
var reused_connection_slots: u32 = 0;

const Owner = struct {
    manager: Manager = .{},
    io: std.Io,
    clock_start: std.Io.Timestamp,
    epoch: u64 = 0,

    fn now(self: *const Owner) u64 {
        return @intCast(self.clock_start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds());
    }

    fn tick(self: *Owner, receive_frames: usize) !void {
        self.epoch += 1;
        var scratch: [17]u8 = undefined;
        try self.manager.beginTick(self.epoch, self.now(), &scratch, .{
            .connection_visits = 4,
            .finalizer_results = 4,
            .events = 128,
            .event_visits = 512,
            .connection = .{
                .send = .{ .steps = 1, .wire_bytes = 17 },
                .receive_frames = receive_frames,
                .receive_bytes = 16 * 17,
                .discard_frames = 16,
            },
        });
        @memset(&scratch, 0);
    }
};

const Pair = struct {
    owner: *Owner,
    native: [2]NativePeer = .{ .{}, .{} },
    ids: [2]Session.Id = undefined,
    blockers: [2]Blocker = .{ .{}, .{} },
    provider_bound: [2]bool = .{ false, false },
    received: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    seen: [2][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    connection_ready: [2]bool = .{ false, false },
    expected_fault: [2]webrtc.Fault = .{ .none, .none },
    closed_seen: [2]bool = .{ false, false },
    accept_packets: bool = true,
    receipt_count: [2]u8 = .{ 0, 0 },
    receipt_seen: [2]u64 = .{ 0, 0 },
    framed_messages: usize = 0,
    cycle: u8,

    fn init(self: *Pair) !void {
        try check(c.rtcSetThreadPoolSize(4));
        for (&self.native, 0..) |*peer, i| {
            self.blockers[i].io = self.owner.io;
            self.ids[i] = try self.owner.manager.admit(.{
                .receive = .{ .frame_bytes = 17, .message_bytes = 64 },
                .incoming_bytes = 16 * 17,
                .outgoing = .{
                    .limits = .{ .{ .frame_bytes = 7, .message_bytes = 64 }, .{ .frame_bytes = 17, .message_bytes = 64 } },
                    .payload_bytes = 64,
                    .buffered_bytes = 1024,
                },
                .negotiation_timeout_ns = 15 * std.time.ns_per_s,
            }, self.now());
            if (self.ids[i].generation > 1) reused_connection_slots += 1;
            self.connection_ready[i] = true;
            try peer.bind(&self.owner.manager, self.ids[i], .{});
            self.provider_bound[i] = true;
            try peer.start(if (i == 0) .offerer else .answerer, "127.0.0.1");
        }
    }

    fn node(self: *Pair, peer: usize) !*Connection {
        return self.owner.manager.get(self.ids[peer]);
    }

    fn beginClose(self: *Pair, peer: usize) !void {
        if (self.connection_ready[peer]) try self.owner.manager.forceClose(self.ids[peer], .requested);
    }

    fn collectFinalizers(self: *Pair) !bool {
        return try self.owner.manager.collectFinalizers(1) != 0;
    }

    fn drainEvents(self: *Pair, allow_input: bool) !void {
        while (try self.owner.manager.nextEvent(allow_input)) |event| {
            const id = event.sessionId();
            var found: ?usize = null;
            for (self.ids, 0..) |known, index| {
                if (self.connection_ready[index] and std.meta.eql(known, id)) found = index;
            }
            const peer = found orelse return error.UnexpectedConnectionEvent;
            switch (event) {
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
                    try expect(std.meta.eql(completion.ticket.session, self.ids[peer]));
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
                        try expect(self.native[peer].peer == -1 and self.native[peer].callbacks.load(.acquire) == 0);
                        finalized_peers += 1;
                    }
                },
            }
        }
    }

    fn awaitPeer(self: *Pair, peer: usize) !void {
        if (!self.connection_ready[peer]) return;
        const start = std.Io.Clock.awake.now(self.owner.io);
        while ((try self.node(peer)).phase != .retired) {
            // Management cleanup must finish even after a deliberately injected
            // ingress failure. It does not validate or consume application data.
            try self.owner.tick(0);
            try self.drainEvents(false);
            if ((try self.node(peer)).phase != .retired) try pause(self.owner.io, start);
        }
    }

    fn deinit(self: *Pair) !void {
        for (&self.blockers) |*blocker| blocker.hold_release.store(true, .release);
        for (0..2) |peer| try self.beginClose(peer);
        for (0..2) |peer| try self.awaitPeer(peer);
        // Global cleanup is a management operation after per-peer barriers.
        c.rtcCleanup();
        for (&self.native, 0..) |*peer, i| {
            try expect(self.blockers[i].callbacks.load(.acquire) == 0 and !self.blockers[i].failed.load(.acquire));
            if (!self.connection_ready[i]) continue;
            if (self.provider_bound[i]) {
                try expect(peer.callbacks.load(.acquire) == 0);
                try expect(peer.fault.load(.acquire) == self.expected_fault[i]);
                try expect(!peer.untracked_handles.load(.acquire));
                try peer.deinit();
            }
            try self.owner.manager.retire(self.ids[i]);
            if (self.owner.manager.get(self.ids[i])) |_| {
                return error.RetiredSessionStillResolves;
            } else |err| try expect(err == error.StaleSession);
        }
    }

    fn drain(self: *Pair) !void {
        var max_discoveries: usize = 0;
        for (&self.native, 0..) |*peer, i| {
            if (!self.connection_ready[i]) continue;
            const current = try self.node(i);
            if (current.phase == .closing or current.phase == .retired) continue;
            const result = try peer.poll(&self.owner.manager, self.now(), 16);
            max_discoveries = @max(max_discoveries, result.discoveries);
            if (result.fault != self.expected_fault[i]) return error.CallbackFailed;
        }
        try self.owner.tick(16 - max_discoveries);
        try self.drainEvents(self.accept_packets);
        self.framed_messages += self.owner.manager.stats.frames_read;
    }

    fn now(self: *const Pair) u64 {
        return self.owner.now();
    }

    fn openChannels(self: *Pair) !bool {
        return (try self.node(0)).session.state == .open and (try self.node(1)).session.state == .open;
    }

    fn exchangeDescription(self: *Pair, source: usize, kind: webrtc.DescriptionType) !void {
        try self.native[source].setLocalDescription(kind);
        const start = std.Io.Clock.awake.now(self.owner.io);
        while (!self.native[source].gathering_done.load(.acquire)) try pause(self.owner.io, start);
        var description: [16 * 1024]u8 = undefined;
        defer @memset(&description, 0);
        const text = try self.native[source].writeLocalDescription(&description);
        try expect(std.mem.indexOf(u8, text, "a=candidate:") != null);
        try expect(std.mem.indexOf(u8, text, "127.0.0.1") != null);
        try expect(std.mem.indexOf(u8, text, " TCP ") == null);
        try expect(std.mem.indexOf(u8, text, "a=fingerprint:") != null);
        try self.native[1 - source].setRemoteDescription(text, kind);
    }
};

fn payload(cycle: u8, sender: u8, channel: u8, sequence: u8) [16]u8 {
    return .{ cycle, sender, channel, sequence, 0, 255, 0, 128, 1, 2, 3, 4, 5, 6, 7, 8 };
}

fn runCycle(io: std.Io, owner: *Owner, cycle: u8) !void {
    var pair: Pair = .{ .owner = owner, .cycle = cycle };
    defer pair.deinit() catch @panic("Native cleanup failed");
    try pair.init();
    try pair.exchangeDescription(0, .offer);
    try pair.exchangeDescription(1, .answer);
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    for (0..32) |sequence| {
        for (0..2) |sender| for (0..2) |channel| {
            const bytes = payload(cycle, @intCast(sender), @intCast(channel), @intCast(sequence));
            _ = try pair.owner.manager.sendCopy(pair.ids[sender], @fromBackingInt(@intCast(channel)), &bytes);
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
    try check(c.rtcSendMessage(pair.native[0].channels[0], &partial, partial.len));
    const partial_start = std.Io.Clock.awake.now(io);
    while ((try pair.node(1)).session.receivers[0].used == 0) {
        try pair.drain();
        try pause(io, partial_start);
    }
    try expect((try pair.node(1)).session.receivers[0].used == 2 and pair.framed_messages == 257);
    try (try pair.node(1)).session.close(pair.ids[1], .requested);
    try expect((try pair.node(1)).session.state == .closed and (try pair.node(1)).session.receivers[0].used == 0);
    // Verify the documented deletion barrier with an actual C++ callback held
    // on a native thread. Releasing it must not depend on the deleting thread.
    const context = &pair.blockers[1];
    const dc = pair.native[1].channels[0];
    try check(c.rtcSetMessageCallback(dc, null));
    try check(c.rtcSetClosedCallback(dc, null));
    c.rtcSetUserPointer(dc, context);
    try check(c.rtcSetMessageCallback(dc, blockedMessage));
    const bytes = payload(cycle, 0, 0, 0);
    var segmenter = try framing.Sender.init(.reliable, &bytes, .{ .frame_bytes = 17 });
    var scratch: [17]u8 = undefined;
    const frame = (try segmenter.write(&scratch)).?;
    try check(c.rtcSendMessage(pair.native[0].channels[0], frame.ptr, @intCast(frame.len)));
    try expect(segmenter.commit());
    const held_start = std.Io.Clock.awake.now(io);
    while (!context.hold_entered.load(.acquire)) try pause(io, held_start);
    try pair.beginClose(1);
    defer context.hold_release.store(true, .release);
    while (pair.native[1].phase.load(.acquire) != .quiescing) try pause(io, held_start);
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try expect(!try pair.collectFinalizers());
    var runtime: Runtime = .{};
    try runtime.start(.{ .ticks = 4 });
    defer runtime.stop();
    for (0..3) |_| {
        try runtime.tick();
        try pair.drain();
    }
    try expect(runtime.ticks == 3 and runtime.state == .running);
    owner_ticks += 3;
    try expect(!try pair.collectFinalizers());
    context.hold_release.store(true, .release);
    try pair.awaitPeer(1);
    try expect(pair.native[1].callbacks.load(.acquire) == 0 and context.callbacks.load(.acquire) == 0 and !context.failed.load(.acquire));
    const disconnect_start = std.Io.Clock.awake.now(io);
    while ((try pair.node(0)).session.state != .closed) {
        try pair.drain();
        try pause(io, disconnect_start);
    }
    try expect((try pair.node(0)).session.close_reason == .transport_closed);
}

fn cancelGathering(owner: *Owner) !void {
    for (0..16) |index| {
        var pair: Pair = .{ .owner = owner, .cycle = @intCast(index + 3) };
        defer pair.deinit() catch @panic("Native cancellation cleanup failed");
        try pair.init();
        try pair.native[0].setLocalDescription(.offer);
        // Do not wait for ICE or callbacks. Teardown must retain their contexts.
    }
}

fn gracefulDisconnect(io: std.Io, owner: *Owner) !void {
    var pair: Pair = .{ .owner = owner, .cycle = 21 };
    defer pair.deinit() catch @panic("Native graceful cleanup failed");
    try pair.init();
    try pair.exchangeDescription(0, .offer);
    try pair.exchangeDescription(1, .answer);
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    try pair.drain();
    const sender = try pair.node(0);
    const id = pair.ids[0];
    pair.accept_packets = false;
    _ = try pair.owner.manager.sendCopy(id, .reliable, &payload(pair.cycle, 0, 0, 0));
    const paused_start = std.Io.Clock.awake.now(io);
    while (pair.receipt_count[0] != 1 or (try pair.native[1].inbox.status()).outstanding != 3) {
        try pair.drain();
        try pause(io, paused_start);
    }
    try expect(pair.received[1][0] == 0 and pair.framed_messages == 0);
    pair.accept_packets = true;
    while (pair.received[1][0] != 1) {
        try pair.drain();
        try pause(io, paused_start);
    }
    try expect(pair.framed_messages == 3);
    backpressure_checks += 1;
    _ = try pair.owner.manager.sendCopy(id, .reliable, &payload(pair.cycle, 0, 0, 1));
    try pair.owner.manager.disconnect(id);
    const closing_start = std.Io.Clock.awake.now(io);
    while (sender.phase != .retired) {
        try pair.drain();
        while (try pair.collectFinalizers()) {}
        if (sender.phase != .retired) try pause(io, closing_start);
    }
    try expect(pair.receipt_count[0] == 2 and pair.closed_seen[0]);
    try expect(sender.session.close_reason == .requested and !sender.flush_expired);
    // Drain completion describes the local provider queue, not peer delivery.
    graceful_closes += 1;
}

fn incomingChannelOverflow(io: std.Io, owner: *Owner) !void {
    var pair: Pair = .{ .owner = owner, .cycle = 20 };
    defer pair.deinit() catch @panic("Native overflow cleanup failed");
    try pair.init();
    try pair.exchangeDescription(0, .offer);
    try pair.exchangeDescription(1, .answer);
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        if (try pair.openChannels()) break;
        try pause(io, start);
    }
    pair.expected_fault[1] = .discovery_capacity;
    for (0..5) |_| {
        const dc = c.rtcCreateDataChannel(pair.native[0].peer, "ExtraDataChannel");
        try check(dc);
        var pending: ?c_int = dc;
        try pair.native[0].retainChannel(&pending);
    }
    const receiver = &pair.native[1];
    const overflow_start = std.Io.Clock.awake.now(io);
    while (receiver.rejected_channels.load(.acquire) == 0) try pause(io, overflow_start);
    try expect(receiver.rejected_channels.load(.acquire) == 1 and receiver.unsubscribe_failures.load(.acquire) == 0);
    const rejected = receiver.overflow.load(.acquire);
    var label: [64]u8 = undefined;
    try expect(rejected >= 0 and c.rtcGetDataChannelLabel(rejected, &label, label.len) > 0);
    try pair.owner.tick(0);
    try expect((try pair.node(1)).session.close_reason == .inbound_failure);
    try expect((try receiver.inbox.status()).outstanding == 0);
    try pair.awaitPeer(1);
    try expect(c.rtcGetDataChannelLabel(rejected, &label, label.len) < 0);
}

fn runChecks(io: std.Io, allocator: std.mem.Allocator) !void {
    var owner: Owner = .{ .io = io, .clock_start = std.Io.Clock.awake.now(io) };
    try owner.manager.init(allocator, io, 1, .{ .connections = 4, .payload_bytes = 4 * 416 });
    defer {
        owner.manager.requestStop() catch @panic("Manager stop failed");
        owner.manager.join() catch @panic("Manager still owns native contexts");
        owner.manager.deinit() catch @panic("Manager deinit failed");
    }
    for (0..3) |cycle| runCycle(io, &owner, @intCast(cycle)) catch |err| {
        std.debug.print("transport cycle {d} failed: {s}\n", .{ cycle, @errorName(err) });
        return err;
    };
    try cancelGathering(&owner);
    try incomingChannelOverflow(io, &owner);
    try gracefulDisconnect(io, &owner);
    try expect(finalized_peers == 42 and owner_ticks == 9 and graceful_closes == 1);
    try expect(backpressure_checks == 1 and reused_connection_slots == 40);
    try expect(owner.manager.records.count == 0 and owner.manager.reserved_bytes == 0);
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
    try output.interface.writeAll("{\"cycles\":3,\"binary_messages\":384,\"drained_receipts\":384,\"framed_messages\":771,\"cancelled_assemblies\":3,\"native_disconnects\":3,\"deletion_barriers\":3,\"cancelled_offers\":16,\"incoming_channel_overflows\":1,\"zig_allocation_leaks\":0,\"finalized_peers\":42,\"owner_ticks_while_closing\":9,\"graceful_closes\":1,\"backpressure_checks\":1,\"reused_connection_slots\":40}\n");
    try output.interface.flush();
    return 0;
}
