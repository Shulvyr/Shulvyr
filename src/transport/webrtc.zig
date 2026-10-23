const std = @import("std");
const core = @import("shulvyr");
pub const native = @import("rtc");
const c = native;
const Session = core.TransportSession;
const framing = core.framing;
const connection = core.connection;
const FrameSink = core.FrameSink;
const buffer = core.transport_buffers;
// The DCEP OPEN header is 12 bytes, followed by label and protocol strings.
// Both supported channels use an empty protocol. Small application limits must
// still allow the longer channel's control message through SCTP.
pub const control_message_bytes = 12 + framing.Channel.unreliable.label().len;

pub const Role = enum { offerer, answerer };
pub const DescriptionType = enum { offer, answer };
pub const Phase = enum(u8) { uninitialized, bound, starting, started, quiescing, quiesced };
pub const Fault = enum(u8) { none, invalid_frame, invalid_channel, discovery_capacity, delivery_failure, native_call, transport_failed, wrong_handle };
pub const Config = struct { max_description_bytes: usize = 16 * 1024 };
pub const Poll = struct { discoveries: usize = 0, opened: usize = 0, fault: Fault = .none };

/// Optional libdatachannel adapter. One fixed address through successful native
/// finalization. Call bind before start, then keep ticking the owning manager.
/// Its allocator/inbox and this context outlive all callbacks and returned tasks.
pub fn Peer(comptime receive_capacity: usize, comptime discovery_capacity: usize) type {
    return struct {
        const Self = @This();
        const Inbox = core.Inbox(receive_capacity);
        const Binding = struct { parent: *Self, channel: framing.Channel, id: c_int = -1 };

        phase: std.atomic.Value(Phase) = .init(.uninitialized),
        fault: std.atomic.Value(Fault) = .init(.none),
        closing: std.atomic.Value(bool) = .init(false),
        gathering_done: std.atomic.Value(bool) = .init(false),
        callbacks: std.atomic.Value(u32) = .init(0),
        rejected_channels: std.atomic.Value(u32) = .init(0),
        unsubscribe_failures: std.atomic.Value(u32) = .init(0),
        untracked_handles: std.atomic.Value(bool) = .init(false),
        overflow: std.atomic.Value(c_int) = .init(-1),
        native_state: std.atomic.Value(c.rtcState) = .init(c.RTC_NEW),
        io: std.Io = undefined,
        session_id: Session.Id = undefined,
        inbox: *Inbox = undefined,
        node_phase: *const connection.Phase = undefined,
        node_bytes: []const u8 = &.{},
        receive_storage: [2][]const u8 = .{ &.{}, &.{} },
        send_limits: [2]usize = .{ 0, 0 },
        native_message_bytes: usize = 0,
        config: Config = .{},
        peer: c_int = -1,
        channels: [2]c_int = @splat(-1),
        bindings: [2]Binding = undefined,
        opened: [2]bool = .{ false, false },
        discoveries: core.Mailbox(c_int, discovery_capacity) = .{},
        pending: ?c_int = null,
        extra_owned: [discovery_capacity + 2]c_int = @splat(-1),
        last_ns: u64 = 0,
        local_set: bool = false,
        remote_set: bool = false,

        /// Successful bind moves the sink/finalizer into the manager before any
        /// native object exists. Even a later failed start needs finalization.
        pub fn bind(self: *Self, manager: anytype, id: Session.Id, config: Config) !void {
            if (self.phase.load(.acquire) != .uninitialized) return error.AlreadyBound;
            if (config.max_description_bytes == 0 or config.max_description_bytes > std.math.maxInt(c_int) - 1) return error.InvalidLimits;
            const node = try manager.get(id);
            if (node.phase != .reserved) return error.NotReserved;
            if (buffer.overlaps(std.mem.asBytes(self), std.mem.asBytes(node))) return error.AliasedContext;
            for (node.session.receivers) |receiver| {
                if (buffer.overlaps(std.mem.asBytes(self), receiver.storage)) return error.AliasedContext;
            }
            try self.discoveries.init();
            errdefer self.* = .{};
            self.io = manager.io;
            self.session_id = id;
            self.inbox = &node.inbox;
            self.node_phase = &node.phase;
            self.node_bytes = std.mem.asBytes(node);
            for (node.session.receivers, 0..) |receiver, index| self.receive_storage[index] = receiver.storage;
            self.native_message_bytes = @max(control_message_bytes, self.inbox.config.frame_bytes);
            for (node.outbox.config.limits, 0..) |limits, index| {
                self.send_limits[index] = limits.frame_bytes;
                self.native_message_bytes = @max(self.native_message_bytes, limits.frame_bytes);
            }
            self.config = config;
            self.last_ns = node.last_ns;
            for (&self.bindings, 0..) |*binding, index| binding.* = .{ .parent = self, .channel = @fromBackingInt(@intCast(index)) };
            var provider: ?connection.Provider = .{
                .sink = .{ .session_id = id, .context = self, .buffered = buffered, .send = send },
                .finalizer = .{ .session = id, .context = self, .finalize = finalize },
            };
            try manager.attach(id, &provider);
            self.phase.store(.bound, .release);
        }

        fn ownerLive(self: *const Self) error{ Closed, NotStarted }!void {
            const phase = self.phase.load(.acquire);
            if (phase == .quiescing or phase == .quiesced) return error.Closed;
            if (phase != .started) return error.NotStarted;
            // The owner may have submitted cleanup before its worker started.
            if (self.node_phase.* == .closing or self.node_phase.* == .retired) return error.Closed;
        }

        fn check(result: c_int) error{NativeCallFailed}!void {
            if (result < 0) return error.NativeCallFailed;
        }

        fn stop(self: *Self, fault: Fault, reason: core.inbound.StopReason) void {
            _ = self.fault.cmpxchgStrong(.none, fault, .acq_rel, .acquire);
            self.inbox.stop(self.session_id, reason) catch {
                _ = self.fault.cmpxchgStrong(.none, .delivery_failure, .acq_rel, .acquire);
            };
        }

        pub fn start(self: *Self, role: Role, bind_address: ?[:0]const u8) !void {
            if (self.phase.load(.acquire) != .bound) return error.NotBound;
            if (self.node_phase.* != .negotiating) return error.Closed;
            if (bind_address) |address| {
                if (std.mem.indexOfScalar(u8, address, 0) != null) return error.EmbeddedNull;
            }
            self.phase.store(.starting, .release);
            errdefer self.stop(.native_call, .delivery_failure);
            var config = std.mem.zeroes(c.rtcConfiguration);
            config.bindAddress = if (bind_address) |address| address.ptr else null;
            config.disableAutoNegotiation = true;
            config.maxMessageSize = @intCast(self.native_message_bytes);
            self.peer = c.rtcCreatePeerConnection(&config);
            try check(self.peer);
            c.rtcSetUserPointer(self.peer, self);
            try check(c.rtcSetDataChannelCallback(self.peer, incoming));
            try check(c.rtcSetGatheringStateChangeCallback(self.peer, gathering));
            try check(c.rtcSetStateChangeCallback(self.peer, stateChanged));
            if (role == .offerer) {
                for (0..2) |index| {
                    var options = std.mem.zeroes(c.rtcDataChannelInit);
                    options.reliability.unordered = index == 1;
                    options.reliability.unreliable = index == 1;
                    const channel: framing.Channel = @fromBackingInt(@intCast(index));
                    self.channels[index] = c.rtcCreateDataChannelEx(self.peer, channel.label(), &options);
                    try check(self.channels[index]);
                    try self.bindChannel(index);
                }
            }
            self.phase.store(.started, .release);
        }

        fn bindChannel(self: *Self, index: usize) !void {
            self.bindings[index].id = self.channels[index];
            c.rtcSetUserPointer(self.channels[index], &self.bindings[index]);
            try check(c.rtcSetMessageCallback(self.channels[index], message));
            try check(c.rtcSetClosedCallback(self.channels[index], closed));
        }

        fn from(raw: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(raw.?));
        }

        fn gathering(pc: c_int, state: c.rtcGatheringState, raw: ?*anyopaque) callconv(.c) void {
            const self = from(raw);
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            defer _ = self.callbacks.fetchSub(1, .acq_rel);
            if (self.closing.load(.acquire)) return;
            if (pc != self.peer) return self.stop(.wrong_handle, .delivery_failure);
            if (state == c.RTC_GATHERING_COMPLETE) self.gathering_done.store(true, .release);
        }

        fn stateChanged(pc: c_int, state: c.rtcState, raw: ?*anyopaque) callconv(.c) void {
            const self = from(raw);
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            defer _ = self.callbacks.fetchSub(1, .acq_rel);
            if (self.closing.load(.acquire)) return;
            if (pc != self.peer) return self.stop(.wrong_handle, .delivery_failure);
            self.native_state.store(state, .release);
            if (state == c.RTC_FAILED) self.stop(.transport_failed, .transport_failed);
            if (state == c.RTC_CLOSED) self.inbox.stop(self.session_id, .transport_closed) catch self.stop(.delivery_failure, .delivery_failure);
        }

        fn incoming(pc: c_int, dc: c_int, raw: ?*anyopaque) callconv(.c) void {
            const self = from(raw);
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            defer _ = self.callbacks.fetchSub(1, .acq_rel);
            if (pc != self.peer or dc < 0) {
                if (dc >= 0) self.untracked_handles.store(true, .release);
                return self.stop(.wrong_handle, .delivery_failure);
            }
            // An incoming handle is owned even after logical closure. The
            // management worker unregisters this callback before draining it.
            var pending: ?c_int = dc;
            self.discoveries.send(self.io, &pending) catch {
                if (self.overflow.cmpxchgStrong(-1, dc, .acq_rel, .acquire) != null) self.untracked_handles.store(true, .release);
                self.stop(.discovery_capacity, .delivery_failure);
                // This native callback is serialized by a recursive mutex.
                // Unsubscribe here to prevent another published overflow handle.
                // Deletion stays on the management worker, including retries.
                if (c.rtcSetDataChannelCallback(pc, null) < 0) _ = self.unsubscribe_failures.fetchAdd(1, .release);
                _ = self.rejected_channels.fetchAdd(1, .release);
            };
        }

        fn message(id: c_int, bytes: [*c]const u8, size: c_int, raw: ?*anyopaque) callconv(.c) void {
            const binding: *Binding = @ptrCast(@alignCast(raw.?));
            const self = binding.parent;
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            defer _ = self.callbacks.fetchSub(1, .acq_rel);
            if (self.closing.load(.acquire)) return;
            if (id < 0 or id != binding.id) return self.stop(.wrong_handle, .delivery_failure);
            if (size < 2 or bytes == null or @as(usize, @intCast(size)) > self.inbox.config.frame_bytes) return self.stop(.invalid_frame, .invalid_frame);
            self.inbox.post(self.session_id, binding.channel, bytes[0..@intCast(size)]) catch |err| switch (err) {
                error.Closed => {},
                error.InvalidFrame => self.stop(.invalid_frame, .invalid_frame),
                error.QueueFull, error.PayloadBudgetExceeded, error.OutOfMemory => {
                    _ = self.fault.cmpxchgStrong(.none, .delivery_failure, .acq_rel, .acquire);
                },
                else => self.stop(.delivery_failure, .delivery_failure),
            };
        }

        fn closed(id: c_int, raw: ?*anyopaque) callconv(.c) void {
            const binding: *Binding = @ptrCast(@alignCast(raw.?));
            const self = binding.parent;
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            defer _ = self.callbacks.fetchSub(1, .acq_rel);
            if (self.closing.load(.acquire)) return;
            if (id < 0 or id != binding.id) return self.stop(.wrong_handle, .delivery_failure);
            self.inbox.stop(self.session_id, .transport_closed) catch self.stop(.delivery_failure, .delivery_failure);
        }

        /// No native getter runs once the connection hands cleanup to its worker.
        pub fn poll(self: *Self, manager: anytype, now_ns: u64, limit: usize) !Poll {
            try self.ownerLive();
            const node = try manager.get(self.session_id);
            if (&node.inbox != self.inbox) return error.WrongConnection;
            if (now_ns < self.last_ns or now_ns < manager.last_ns) return error.ClockWentBackwards;
            self.last_ns = now_ns;
            var result: Poll = .{};
            if (self.fault.load(.acquire) != .none) return .{ .fault = self.fault.load(.acquire) };
            while (result.discoveries < limit) {
                if (self.pending == null) self.pending = (try self.discoveries.receive(self.io)) orelse break;
                result.discoveries += 1;
                const dc = self.pending.?;
                const index = self.channelIndex(dc) catch |err| {
                    self.stop(if (err == error.InvalidChannel) .invalid_channel else .native_call, .invalid_channel);
                    result.fault = self.fault.load(.acquire);
                    return result;
                };
                if (self.channels[index] >= 0) {
                    self.stop(.invalid_channel, .invalid_channel);
                    result.fault = self.fault.load(.acquire);
                    return result;
                }
                self.channels[index] = dc;
                self.pending = null;
                self.bindChannel(index) catch {
                    self.stop(.native_call, .delivery_failure);
                    result.fault = self.fault.load(.acquire);
                    return result;
                };
            }
            for (self.channels, 0..) |dc, index| {
                if (dc < 0 or self.opened[index] or !c.rtcIsOpen(dc)) continue;
                const actual_index = self.channelIndex(dc) catch |err| {
                    self.stop(if (err == error.InvalidChannel) .invalid_channel else .native_call, .invalid_channel);
                    result.fault = self.fault.load(.acquire);
                    return result;
                };
                if (actual_index != index) {
                    self.stop(.invalid_channel, .invalid_channel);
                    result.fault = self.fault.load(.acquire);
                    return result;
                }
                const maximum = c.rtcMaxMessageSize(dc);
                if (maximum < 2) {
                    self.stop(.native_call, .delivery_failure);
                    result.fault = self.fault.load(.acquire);
                    return result;
                }
                const channel: framing.Channel = @fromBackingInt(@intCast(index));
                self.send_limits[index] = try manager.limitSendFrame(self.session_id, channel, @intCast(maximum));
                try manager.channelOpened(self.session_id, channel, .required(channel), now_ns);
                self.opened[index] = true;
                result.opened += 1;
            }
            result.fault = self.fault.load(.acquire);
            return result;
        }

        fn channelIndex(_: *Self, dc: c_int) !usize {
            var label: [64]u8 = undefined;
            const length = c.rtcGetDataChannelLabel(dc, &label, label.len);
            try check(length);
            if (length < 1 or length > label.len or label[@intCast(length - 1)] != 0) return error.InvalidChannel;
            const channel = framing.Channel.fromLabel(label[0..@intCast(length - 1)]) orelse return error.InvalidChannel;
            var protocol: [1]u8 = undefined;
            if (c.rtcGetDataChannelProtocol(dc, &protocol, protocol.len) != 1 or protocol[0] != 0) return error.InvalidChannel;
            var reliability: c.rtcReliability = undefined;
            try check(c.rtcGetDataChannelReliability(dc, &reliability));
            if (reliability.unordered != (channel == .unreliable) or reliability.unreliable != (channel == .unreliable) or
                reliability.maxRetransmits != 0 or reliability.maxPacketLifeTime != 0) return error.InvalidChannel;
            return @backingInt(channel);
        }

        pub fn setLocalDescription(self: *Self, kind: DescriptionType) !void {
            try self.ownerLive();
            if (self.local_set) return error.DescriptionAlreadySet;
            try check(c.rtcSetLocalDescription(self.peer, @tagName(kind)));
            self.local_set = true;
        }

        /// Caller verifies identity before passing a stripped, bounded SDP.
        /// Native code copies it during this synchronous call. Never log SDP.
        pub fn setRemoteDescription(self: *Self, text: [:0]const u8, kind: DescriptionType) !void {
            try self.ownerLive();
            if (self.remote_set) return error.DescriptionAlreadySet;
            if (text.len == 0) return error.EmptyDescription;
            if (text.len > self.config.max_description_bytes) return error.DescriptionTooLarge;
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNull;
            try check(c.rtcSetRemoteDescription(self.peer, text.ptr, @tagName(kind)));
            self.remote_set = true;
        }

        /// Returns a caller-owned buffer view only after full ICE gathering.
        /// The trailing sentinel is retained for native consumers, excluded here.
        pub fn writeLocalDescription(self: *Self, output: []u8) ![:0]const u8 {
            try self.ownerLive();
            if (self.overlapsStorage(output)) return error.AliasedBuffer;
            if (!self.gathering_done.load(.acquire)) return error.NotGathered;
            if (output.len == 0 or output.len > std.math.maxInt(c_int)) return error.InvalidBuffer;
            const needed = c.rtcGetLocalDescription(self.peer, null, 0);
            try check(needed);
            if (needed < 1 or needed - 1 > self.config.max_description_bytes) return error.DescriptionTooLarge;
            if (needed > output.len) return error.NoSpace;
            const count = c.rtcGetLocalDescription(self.peer, output.ptr, @intCast(output.len));
            try check(count);
            if (count != needed or output[@intCast(count - 1)] != 0) return error.InvalidNativeDescription;
            return output[0..@intCast(count - 1) :0];
        }

        /// Trusted native integration only. Moves an extra same-peer handle on
        /// success. The caller retains it on failure and must arrange cleanup.
        pub fn retainChannel(self: *Self, pending: *?c_int) !void {
            try self.ownerLive();
            if (self.overlapsStorage(std.mem.asBytes(pending))) return error.AliasedTransfer;
            const dc = pending.* orelse return error.EmptyTransfer;
            if (dc < 0) return error.InvalidHandle;
            if (self.pending == dc or self.overflow.load(.acquire) == dc) return error.DuplicateHandle;
            for (self.channels) |known| if (known == dc) return error.DuplicateHandle;
            for (self.extra_owned) |known| if (known == dc) return error.DuplicateHandle;
            for (&self.extra_owned) |*slot| {
                if (slot.* >= 0) continue;
                slot.* = dc;
                pending.* = null;
                return;
            }
            return error.ChannelCapacity;
        }

        fn overlapsStorage(self: *Self, bytes: []const u8) bool {
            if (buffer.overlaps(bytes, std.mem.asBytes(self)) or buffer.overlaps(bytes, self.node_bytes)) return true;
            for (self.receive_storage) |storage| if (buffer.overlaps(bytes, storage)) return true;
            return false;
        }

        fn buffered(raw: *anyopaque, channel: framing.Channel) FrameSink.Error!u64 {
            const self = from(raw);
            self.ownerLive() catch return error.Closed;
            const dc = self.channels[@backingInt(channel)];
            if (dc < 0) return error.Closed;
            const amount = c.rtcGetBufferedAmount(dc);
            if (amount < 0) return error.Failed;
            return @intCast(amount);
        }

        fn send(raw: *anyopaque, channel: framing.Channel, frame: []const u8) FrameSink.Error!FrameSink.Admission {
            const self = from(raw);
            self.ownerLive() catch return error.Closed;
            if (frame.len < 2 or frame.len > self.send_limits[@backingInt(channel)]) return error.Failed;
            const dc = self.channels[@backingInt(channel)];
            if (dc < 0 or !c.rtcIsOpen(dc)) return error.Closed;
            if (c.rtcSendMessage(dc, frame.ptr, @intCast(frame.len)) < 0) return error.Failed;
            return .accepted;
        }

        fn deleteChannel(dc: *c_int) error{Failed}!void {
            if (dc.* < 0) return;
            if (c.rtcDeleteDataChannel(dc.*) < 0) return error.Failed;
            dc.* = -1;
        }

        fn finalize(raw: *anyopaque) error{Failed}!void {
            const self = from(raw);
            self.closing.store(true, .release);
            self.phase.store(.quiescing, .release);
            if (self.peer >= 0) {
                if (c.rtcSetDataChannelCallback(self.peer, null) < 0 or
                    c.rtcSetGatheringStateChangeCallback(self.peer, null) < 0 or
                    c.rtcSetStateChangeCallback(self.peer, null) < 0) return error.Failed;
            }
            while (true) {
                if (self.pending == null) self.pending = self.discoveries.receive(self.io) catch return error.Failed;
                if (self.pending) |*dc| {
                    try deleteChannel(dc);
                    self.pending = null;
                } else break;
            }
            var overflow = self.overflow.load(.acquire);
            try deleteChannel(&overflow);
            self.overflow.store(overflow, .release);
            for (&self.channels) |*dc| try deleteChannel(dc);
            for (&self.extra_owned) |*dc| try deleteChannel(dc);
            if (self.peer >= 0) {
                if (c.rtcDeletePeerConnection(self.peer) < 0) return error.Failed;
                self.peer = -1;
            }
            // A second overflow after failed native unsubscription loses handle
            // ownership. Never assert cleanup success or release this context.
            // The backend must stop admission and use process-level recovery.
            if (self.callbacks.load(.acquire) != 0 or self.untracked_handles.load(.acquire)) return error.Failed;
            self.phase.store(.quiesced, .release);
        }

        pub fn deinit(self: *Self) error{NotQuiesced}!void {
            if (self.phase.load(.acquire) != .quiesced) return error.NotQuiesced;
            self.discoveries.close(self.io);
            self.* = .{};
        }
    };
}

const TestPeer = Peer(16, 4);
const TestManager = core.ConnectionManager(8, 16, 2);
const test_config: connection.Config = .{
    .receive = .{ .frame_bytes = 17, .message_bytes = 64 },
    .incoming_bytes = 16 * 17,
    .outgoing = .{ .limits = .{ .{ .frame_bytes = 7, .message_bytes = 64 }, .{ .frame_bytes = 17, .message_bytes = 64 } }, .payload_bytes = 64, .buffered_bytes = 1024 },
};
const TestFixture = struct {
    owner: u64 = 91,
    connection_config: connection.Config = test_config,
    manager: TestManager = .{},
    peer: TestPeer = .{},
    id: Session.Id = undefined,
    epoch: u64 = 0,
    finalized: bool = false,
    restore_channel: ?c_int = null,

    fn init(self: *TestFixture, config: Config) !void {
        c.rtcInitLogger(c.RTC_LOG_NONE, null);
        try TestPeer.check(c.rtcSetThreadPoolSize(4));
        const charge = try TestManager.reservationBytes(self.connection_config);
        try self.manager.init(std.testing.allocator, std.testing.io, self.owner, .{ .connections = 1, .payload_bytes = charge });
        self.id = try self.manager.admit(self.connection_config, 0);
        try self.peer.bind(&self.manager, self.id, config);
    }

    fn tick(self: *TestFixture) !void {
        self.epoch += 1;
        var scratch: [128]u8 = undefined;
        try self.manager.beginTick(self.epoch, self.epoch, &scratch, .{
            .connection_visits = 1,
            .finalizer_results = 2,
            .events = 32,
            .event_visits = 32,
            .connection = .{ .send = .{ .steps = 1, .wire_bytes = 128 }, .receive_frames = 16, .receive_bytes = 272, .discard_frames = 16 },
        });
    }

    fn finish(self: *TestFixture) !void {
        try self.manager.forceClose(self.id, .requested);
        const start = std.Io.Clock.awake.now(std.testing.io);
        while (!self.finalized) {
            try self.tick();
            while (try self.manager.nextEvent(false)) |event| switch (event) {
                .finalized => |done| {
                    try std.testing.expect(done.task.?.context == @as(*anyopaque, &self.peer));
                    self.finalized = true;
                },
                .cleanup_failed => |id| {
                    if (self.restore_channel) |dc| {
                        self.peer.channels[0] = dc;
                        self.restore_channel = null;
                    }
                    try self.manager.retryFinalizer(id);
                },
                else => {},
            };
            if (start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.NativeTestTimeout;
            try std.Thread.yield();
        }
    }

    fn deinit(self: *TestFixture) void {
        self.finish() catch @panic("Native test finalization failed");
        c.rtcCleanup();
        self.peer.deinit() catch unreachable;
        self.manager.retire(self.id) catch unreachable;
        self.manager.requestStop() catch unreachable;
        self.manager.join() catch unreachable;
        self.manager.deinit() catch unreachable;
    }
};

test "WebRTC binding transfers cleanup ownership before creating native resources" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    try std.testing.expectEqual(Phase.bound, fixture.peer.phase.load(.acquire));
    try std.testing.expectEqual(@as(c_int, -1), fixture.peer.peer);
    try std.testing.expectEqual(connection.Phase.negotiating, (try fixture.manager.get(fixture.id)).phase);
    try std.testing.expectError(error.NotStarted, fixture.peer.setLocalDescription(.offer));
    try std.testing.expectError(error.NotQuiesced, fixture.peer.deinit());
    try std.testing.expectError(error.AlreadyBound, fixture.peer.bind(&fixture.manager, fixture.id, .{}));
}

test "WebRTC callback copies retain admission credits and sticky queue failure" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    const binding = &fixture.peer.bindings[0];
    binding.id = 7;
    var bytes: [17]u8 = @splat(42);
    bytes[0] = 0;
    for (0..16) |_| TestPeer.message(7, &bytes, bytes.len, binding);
    @memset(&bytes, 99);
    TestPeer.message(7, &bytes, bytes.len, binding);
    TestPeer.closed(7, binding);
    try std.testing.expectEqual(core.inbound.StopReason.queue_full, (try fixture.peer.inbox.status()).reason.?);
    for (0..16) |_| {
        var lease = (try fixture.peer.inbox.receive()).?;
        defer lease.deinit();
        try std.testing.expect(lease.bytes()[0] == 0 and lease.bytes()[1] == 42);
    }
    try std.testing.expectEqual(@as(usize, 0), (try fixture.peer.inbox.status()).outstanding);
    try std.testing.expectEqual(@as(u32, 0), fixture.peer.callbacks.load(.acquire));
}

test "WebRTC malformed callback input and native handle mismatch stop admission" {
    for ([_]c_int{ -1, 17, 18, 0, 1 }, 0..) |length, index| {
        var fixture: TestFixture = .{};
        try fixture.init(.{});
        defer fixture.deinit();
        fixture.peer.bindings[0].id = 7;
        var bytes: [18]u8 = @splat(0);
        TestPeer.message(7, if (index == 1) null else &bytes, length, &fixture.peer.bindings[0]);
        try std.testing.expectEqual(core.inbound.StopReason.invalid_frame, (try fixture.peer.inbox.status()).reason.?);
        try std.testing.expectEqual(@as(usize, 0), (try fixture.peer.inbox.status()).outstanding);
    }
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    fixture.peer.bindings[0].id = 7;
    var bytes: [2]u8 = .{ 0, 1 };
    TestPeer.message(8, &bytes, bytes.len, &fixture.peer.bindings[0]);
    try std.testing.expectEqual(Fault.wrong_handle, fixture.peer.fault.load(.acquire));
    try std.testing.expectEqual(core.inbound.StopReason.delivery_failure, (try fixture.peer.inbox.status()).reason.?);
}

test "WebRTC native state distinguishes terminal failure from temporary disconnection" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.peer.start(.answerer, "127.0.0.1");
    TestPeer.stateChanged(fixture.peer.peer, c.RTC_DISCONNECTED, &fixture.peer);
    try std.testing.expectEqual(null, (try fixture.peer.inbox.status()).reason);
    TestPeer.stateChanged(fixture.peer.peer, c.RTC_FAILED, &fixture.peer);
    try fixture.tick();
    try std.testing.expectEqual(Session.CloseReason.transport_failure, (try fixture.manager.get(fixture.id)).session.close_reason.?);
    try std.testing.expectEqual(Fault.transport_failed, fixture.peer.fault.load(.acquire));
}

test "WebRTC description limits, embedded null and output aliases reject before native parsing" {
    var fixture: TestFixture = .{};
    try fixture.init(.{ .max_description_bytes = 8 });
    defer fixture.deinit();
    try std.testing.expectError(error.EmbeddedNull, fixture.peer.start(.answerer, "127\x00.0"));
    try fixture.peer.start(.answerer, "127.0.0.1");
    try std.testing.expectError(error.EmptyDescription, fixture.peer.setRemoteDescription("", .offer));
    try std.testing.expectError(error.DescriptionTooLarge, fixture.peer.setRemoteDescription("123456789", .offer));
    try std.testing.expectError(error.EmbeddedNull, fixture.peer.setRemoteDescription("v\x00x", .offer));
    try std.testing.expectError(error.AliasedBuffer, fixture.peer.writeLocalDescription(std.mem.asBytes(&fixture.peer)));
    const storage = (try fixture.manager.get(fixture.id)).session.receivers[0].storage;
    try std.testing.expectError(error.AliasedBuffer, fixture.peer.writeLocalDescription(storage));
    try std.testing.expect(!fixture.peer.remote_set);
}

test "WebRTC failed native deletion retains context and handle progress until retry" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.peer.start(.offerer, "127.0.0.1");
    const real = fixture.peer.channels[0];
    // Fault-inject a rejected native handle while retaining the actual owned
    // handle in this fixture. Restore only after the failed task has returned.
    fixture.restore_channel = real;
    fixture.peer.channels[0] = std.math.maxInt(c_int);
    try fixture.manager.forceClose(fixture.id, .requested);
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (!(try fixture.manager.get(fixture.id)).failure_pending) {
        _ = try fixture.manager.collectFinalizers(1);
        if (start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() > 10 * std.time.ns_per_s) return error.NativeTestTimeout;
        try std.Thread.yield();
    }
    try std.testing.expectEqual(Phase.quiescing, fixture.peer.phase.load(.acquire));
    try std.testing.expectError(error.NotQuiesced, fixture.peer.deinit());
    try std.testing.expectError(error.NotRetired, fixture.manager.retire(fixture.id));
    var label: [64]u8 = undefined;
    try std.testing.expect(c.rtcGetDataChannelLabel(real, &label, label.len) > 0);
    try std.testing.expectEqual(@as(usize, 416), fixture.manager.reserved_bytes);
    try fixture.finish();
    try std.testing.expectEqual(Phase.quiesced, fixture.peer.phase.load(.acquire));
    try std.testing.expect(c.rtcGetDataChannelLabel(real, &label, label.len) < 0);
}

test "WebRTC discovery overflow retains its handle for worker deletion" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.peer.start(.answerer, "127.0.0.1");
    for (0..5) |_| {
        const dc = c.rtcCreateDataChannel(fixture.peer.peer, "Extra");
        try TestPeer.check(dc);
        TestPeer.incoming(fixture.peer.peer, dc, &fixture.peer);
    }
    try std.testing.expectEqual(@as(u32, 1), fixture.peer.rejected_channels.load(.acquire));
    const overflow = fixture.peer.overflow.load(.acquire);
    var label: [64]u8 = undefined;
    try std.testing.expect(overflow >= 0 and c.rtcGetDataChannelLabel(overflow, &label, label.len) > 0);
    try fixture.finish();
    try std.testing.expect(c.rtcGetDataChannelLabel(overflow, &label, label.len) < 0);
    try std.testing.expect(!fixture.peer.untracked_handles.load(.acquire));
}

test "WebRTC rejects remote channel settings while retaining their native handles" {
    for (0..3) |kind| {
        var fixture: TestFixture = .{};
        try fixture.init(.{});
        defer fixture.deinit();
        try fixture.peer.start(.answerer, "127.0.0.1");
        var options = std.mem.zeroes(c.rtcDataChannelInit);
        if (kind == 1) options.protocol = "unexpected";
        if (kind == 2) options.reliability.unordered = true;
        const dc = c.rtcCreateDataChannelEx(fixture.peer.peer, if (kind == 0) "OtherChannel" else "ReliableDataChannel", &options);
        try TestPeer.check(dc);
        TestPeer.incoming(fixture.peer.peer, dc, &fixture.peer);
        const polled = try fixture.peer.poll(&fixture.manager, 0, 1);
        try std.testing.expectEqual(Fault.invalid_channel, polled.fault);
        try std.testing.expectEqual(dc, fixture.peer.pending.?);
        try fixture.tick();
        try std.testing.expectEqual(Session.CloseReason.invalid_channel, (try fixture.manager.get(fixture.id)).session.close_reason.?);
    }
}

test "WebRTC native handle transfers retain ownership on duplicate and capacity errors" {
    var fixture: TestFixture = .{};
    try fixture.init(.{});
    defer fixture.deinit();
    try fixture.peer.start(.offerer, "127.0.0.1");
    var duplicate: ?c_int = fixture.peer.channels[0];
    try std.testing.expectError(error.DuplicateHandle, fixture.peer.retainChannel(&duplicate));
    try std.testing.expect(duplicate != null);
    for (0..6) |_| {
        const dc = c.rtcCreateDataChannel(fixture.peer.peer, "Extra");
        try TestPeer.check(dc);
        var pending: ?c_int = dc;
        try fixture.peer.retainChannel(&pending);
        try std.testing.expectEqual(null, pending);
    }
    // No native object is created beyond capacity. This synthetic unused ID
    // tests admission failure without leaving an unowned C API allocation.
    var full: ?c_int = std.math.maxInt(c_int);
    try std.testing.expectError(error.ChannelCapacity, fixture.peer.retainChannel(&full));
    try std.testing.expect(full != null);
}

test "WebRTC small application frame limits still permit both DCEP channel opens" {
    for (0..2) |profile| {
        var left: TestFixture = .{};
        var right: TestFixture = .{ .owner = 92 };
        if (profile == 1) {
            left.connection_config.receive.frame_bytes = 64;
            right.connection_config.receive.frame_bytes = 64;
            for (&left.connection_config.outgoing.limits) |*limits| limits.frame_bytes = 128;
        }
        try left.init(.{});
        right.init(.{}) catch |err| {
            left.deinit();
            return err;
        };
        defer {
            // Global cleanup can run only after both peers' callback barriers.
            left.finish() catch @panic("Left handshake cleanup failed");
            right.finish() catch @panic("Right handshake cleanup failed");
            left.deinit();
            right.deinit();
        }
        try left.peer.start(.offerer, "127.0.0.1");
        try right.peer.start(.answerer, "127.0.0.1");
        var sdp: [16 * 1024]u8 = undefined;
        defer @memset(&sdp, 0);
        for (0..2) |index| {
            const source = if (index == 0) &left else &right;
            const target = if (index == 0) &right else &left;
            const kind: DescriptionType = if (index == 0) .offer else .answer;
            try source.peer.setLocalDescription(kind);
            const start = std.Io.Clock.awake.now(std.testing.io);
            while (!source.peer.gathering_done.load(.acquire)) {
                if (start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() > 5 * std.time.ns_per_s) return error.NativeGatherTimeout;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try target.peer.setRemoteDescription(try source.peer.writeLocalDescription(&sdp), kind);
            @memset(&sdp, 0);
        }
        const start = std.Io.Clock.awake.now(std.testing.io);
        while (true) {
            _ = try left.peer.poll(&left.manager, left.epoch + 1, 4);
            _ = try right.peer.poll(&right.manager, right.epoch + 1, 4);
            try left.tick();
            try right.tick();
            if ((try left.manager.get(left.id)).session.state == .open and
                (try right.manager.get(right.id)).session.state == .open) break;
            if (start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() > 5 * std.time.ns_per_s) return error.NativeHandshakeTimeout;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        for (left.peer.opened) |opened| try std.testing.expect(opened);
        for (right.peer.opened) |opened| try std.testing.expect(opened);
        if (profile == 1) {
            const node = try left.manager.get(left.id);
            try std.testing.expectEqual(@as(usize, 64), node.outbox.config.limits[0].frame_bytes);
            var payload: [64]u8 = @splat(42);
            _ = try left.manager.sendCopy(left.id, .reliable, &payload);
            var received = false;
            const sent = std.Io.Clock.awake.now(std.testing.io);
            while (!received) {
                try left.tick();
                try right.tick();
                while (try left.manager.nextEvent(true)) |_| {}
                while (try right.manager.nextEvent(true)) |event| {
                    if (event == .message) {
                        try std.testing.expectEqualSlices(u8, &payload, event.message.payload);
                        received = true;
                    }
                }
                if (sent.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds() > 5 * std.time.ns_per_s) return error.NativePayloadTimeout;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(@as(u64, 2), node.outbox.queued[0] - payload.len);
        }
    }
}
