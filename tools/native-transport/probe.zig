const std = @import("std");
const Mailbox = @import("shulvyr").Mailbox;
const c = @import("rtc");

// This development probe owns all contexts until rtcCleanup returns. It uses
// loopback ICE only and never prints SDP, ICE credentials or native log text.
const Event = union(enum) {
    channel: c_int,
    message: struct { id: c_int, bytes: [16]u8 },
};
const Context = struct {
    io: std.Io,
    events: Mailbox(Event, 16) = .{},
    failed: std.atomic.Value(bool) = .init(false),
    gathering_done: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    callbacks: std.atomic.Value(u32) = .init(0),
    hold_entered: std.atomic.Value(bool) = .init(false),
    hold_release: std.atomic.Value(bool) = .init(false),

    fn push(self: *Context, event: Event) void {
        var pending: ?Event = event;
        self.events.send(self.io, &pending) catch {
            self.failed.store(true, .release);
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
    context.push(.{ .channel = dc });
}

fn message(id: c_int, bytes: [*c]const u8, size: c_int, raw: ?*anyopaque) callconv(.c) void {
    const context = Context.from(raw);
    _ = context.callbacks.fetchAdd(1, .acq_rel);
    defer _ = context.callbacks.fetchSub(1, .acq_rel);
    if (context.closing.load(.acquire)) return;
    if (size != 16 or bytes == null) {
        context.failed.store(true, .release);
        return;
    }
    // Copy borrowed callback bytes before returning to C++.
    context.push(.{ .message = .{ .id = id, .bytes = bytes[0..16].* } });
}

fn blockedMessage(_: c_int, _: [*c]const u8, _: c_int, raw: ?*anyopaque) callconv(.c) void {
    const context = Context.from(raw);
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
const Pair = struct {
    contexts: [2]Context,
    peers: [2]c_int = .{ -1, -1 },
    channels: [2][2]c_int = .{ .{ -1, -1 }, .{ -1, -1 } },
    received: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    seen: [2][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    cycle: u8,

    fn init(self: *Pair) !void {
        try check(c.rtcSetThreadPoolSize(4));
        var config = std.mem.zeroes(c.rtcConfiguration);
        config.bindAddress = "127.0.0.1";
        config.disableAutoNegotiation = true;
        config.maxMessageSize = 1024;
        for (&self.contexts, 0..) |*context, i| {
            try context.events.init();
            self.peers[i] = c.rtcCreatePeerConnection(&config);
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
            try check(self.channels[0][i]);
            try check(c.rtcSetMessageCallback(self.channels[0][i], message));
        }
    }

    fn deinit(self: *Pair) !void {
        var failed = false;
        for (&self.contexts) |*context| {
            context.closing.store(true, .release);
            context.hold_release.store(true, .release);
        }
        for (self.peers) |pc| {
            if (pc >= 0) {
                if (c.rtcSetDataChannelCallback(pc, null) < 0) failed = true;
                if (c.rtcSetGatheringStateChangeCallback(pc, null) < 0) failed = true;
            }
        }
        for (&self.contexts) |*context| {
            if (context.events.queue == null) continue;
            while (context.events.receive(context.io) catch {
                failed = true;
                break;
            }) |event| switch (event) {
                .channel => |dc| {
                    if (c.rtcDeleteDataChannel(dc) < 0) failed = true;
                },
                .message => {},
            };
        }
        for (self.channels) |channels| for (channels) |dc| {
            if (dc >= 0 and c.rtcDeleteDataChannel(dc) < 0) failed = true;
        };
        for (self.peers) |pc| {
            if (pc >= 0 and c.rtcDeletePeerConnection(pc) < 0) failed = true;
        }
        // Also completes background destruction before stack contexts expire.
        c.rtcCleanup();
        for (&self.contexts) |*context| {
            context.events.close(context.io);
            if (context.callbacks.load(.acquire) != 0) failed = true;
        }
        if (failed) return error.NativeCleanupFailed;
    }

    fn drain(self: *Pair) !void {
        for (&self.contexts, 0..) |*context, peer| {
            if (context.failed.load(.acquire)) return error.CallbackFailed;
            while (try context.events.receive(context.io)) |event| switch (event) {
                .channel => |dc| {
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
                    }
                    var reliability: c.rtcReliability = undefined;
                    try check(c.rtcGetDataChannelReliability(dc, &reliability));
                    try expect(reliability.unordered == (index.? == 1));
                    try expect(reliability.unreliable == (index.? == 1));
                    try expect(reliability.maxRetransmits == 0 and reliability.maxPacketLifeTime == 0);
                    try check(c.rtcSetMessageCallback(dc, message));
                },
                .message => |event_message| {
                    const bytes = event_message.bytes;
                    const channel: usize = bytes[2];
                    const sequence = bytes[3];
                    try expect(channel < 2 and sequence < 32);
                    try expect(self.channels[peer][channel] == event_message.id);
                    try expect(std.mem.eql(u8, &bytes, &payload(self.cycle, @intCast(1 - peer), @intCast(channel), sequence)));
                    const bit = @as(u32, 1) << @as(u5, @intCast(sequence));
                    try expect(self.seen[peer][channel] & bit == 0);
                    if (channel == 0) try expect(sequence == self.received[peer][channel]);
                    self.seen[peer][channel] |= bit;
                    self.received[peer][channel] += 1;
                },
            };
        }
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

const Delete = struct {
    dc: c_int,
    started: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    result: c_int = -1,

    fn run(self: *Delete) void {
        self.started.store(true, .release);
        self.result = c.rtcDeleteDataChannel(self.dc);
        self.finished.store(true, .release);
    }
};

fn runCycle(io: std.Io, cycle: u8) !void {
    var pair: Pair = .{ .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = cycle };
    defer pair.deinit() catch @panic("Native cleanup failed");
    try pair.init();
    try pair.exchangeDescription(0, "offer");
    try pair.exchangeDescription(1, "answer");
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        try pair.drain();
        var open = true;
        for (pair.channels) |channels| for (channels) |dc| {
            if (dc < 0 or !c.rtcIsOpen(dc)) open = false;
        };
        if (open) break;
        try pause(io, start);
    }
    for (0..32) |sequence| {
        for (pair.channels, 0..) |channels, sender| for (channels, 0..) |dc, channel| {
            const bytes = payload(cycle, @intCast(sender), @intCast(channel), @intCast(sequence));
            const buffered = c.rtcGetBufferedAmount(dc);
            try check(buffered);
            try expect(buffered <= 1024);
            try check(c.rtcSendMessage(dc, &bytes, bytes.len));
        };
        const sent = std.Io.Clock.awake.now(io);
        while (true) {
            try pair.drain();
            var complete = true;
            for (pair.received) |counts| for (counts) |count| {
                if (count != sequence + 1) complete = false;
            };
            if (complete) break;
            try pause(io, sent);
        }
    }
    // Verify the documented deletion barrier with an actual C++ callback held
    // on a native thread. Releasing it must not depend on the deleting thread.
    const context = &pair.contexts[1];
    const dc = pair.channels[1][0];
    try check(c.rtcSetMessageCallback(dc, blockedMessage));
    const bytes = payload(cycle, 0, 0, 0);
    try check(c.rtcSendMessage(pair.channels[0][0], &bytes, bytes.len));
    const held_start = std.Io.Clock.awake.now(io);
    while (!context.hold_entered.load(.acquire)) try pause(io, held_start);
    var deletion: Delete = .{ .dc = dc };
    const thread = try std.Thread.spawn(.{}, Delete.run, .{&deletion});
    {
        defer {
            context.hold_release.store(true, .release);
            thread.join();
            if (deletion.result >= 0) pair.channels[1][0] = -1;
        }
        while (!deletion.started.load(.acquire)) try pause(io, held_start);
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
        try expect(!deletion.finished.load(.acquire));
    }
    try check(deletion.result);
    try expect(context.callbacks.load(.acquire) == 0 and !context.failed.load(.acquire));
}

fn cancelGathering(io: std.Io) !void {
    for (0..16) |_| {
        var pair: Pair = .{ .contexts = .{ .{ .io = io }, .{ .io = io } }, .cycle = 0 };
        defer pair.deinit() catch @panic("Native cancellation cleanup failed");
        try pair.init();
        try check(c.rtcSetLocalDescription(pair.peers[0], "offer"));
        // Do not wait for ICE or callbacks. Teardown must retain their contexts.
    }
}

fn callbackBoundaries(io: std.Io) !void {
    var context: Context = .{ .io = io };
    try context.events.init();
    var bytes = payload(1, 0, 0, 0);
    for (0..16) |_| message(7, &bytes, bytes.len, &context);
    @memset(&bytes, 42);
    // The seventeenth message fails closed and cannot overwrite queued bytes.
    message(7, &bytes, bytes.len, &context);
    try expect(context.failed.load(.acquire));
    for (0..16) |_| {
        const event = (try context.events.receive(io)).?;
        try expect(std.mem.eql(u8, &event.message.bytes, &payload(1, 0, 0, 0)));
    }
    try expect(try context.events.receive(io) == null);
    context.failed.store(false, .release);
    message(7, &bytes, -1, &context);
    try expect(context.failed.load(.acquire));
    context.failed.store(false, .release);
    message(7, null, 16, &context);
    try expect(context.failed.load(.acquire));
    context.failed.store(false, .release);
    message(7, &bytes, 17, &context);
    try expect(context.failed.load(.acquire));
    context.events.close(io);
}

pub fn main(init: std.process.Init) !u8 {
    c.rtcInitLogger(c.RTC_LOG_NONE, null);
    callbackBoundaries(init.io) catch |err| {
        std.debug.print("callback probe failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    for (0..3) |cycle| runCycle(init.io, @intCast(cycle)) catch |err| {
        std.debug.print("transport cycle {d} failed: {s}\n", .{ cycle, @errorName(err) });
        return 1;
    };
    try cancelGathering(init.io);
    var buffer: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try output.interface.writeAll("{\"cycles\":3,\"binary_messages\":384,\"deletion_barriers\":3,\"cancelled_offers\":16,\"callback_boundary_checks\":4}\n");
    try output.interface.flush();
    return 0;
}
