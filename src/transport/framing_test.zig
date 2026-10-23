const std = @import("std");
const framing = @import("framing.zig");
const Session = @import("Session.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;
const limits: framing.Limits = .{ .frame_bytes = 5, .message_bytes = 16, .assembly_timeout_ns = 10 };
const id: Session.Id = .{ .owner = 7, .index = 3, .generation = 4 };

const Fixtures = struct {
    oracle: struct { repository: []const u8, branch: []const u8, revision: []const u8, license: []const u8 },
    send: []const struct { name: []const u8, payload_hex: []const u8, capacity: usize, frames_hex: []const []const u8 = &.{}, @"error": bool = false },
    receive: []const struct {
        name: []const u8,
        reliable: bool,
        limit: usize,
        frames_hex: []const []const u8,
        results: []const struct { pending: bool = false, @"error": bool = false, payload_hex: ?[]const u8 = null },
    },
    boundaries: []const struct {
        length: usize,
        payload_sha256: []const u8,
        frames: []const struct { length: usize, header: u8, sha256: []const u8 },
    },
};

fn load() !std.json.Parsed(Fixtures) {
    return std.json.parseFromSlice(Fixtures, allocator, @embedFile("fixtures/framing.json"), .{});
}

fn unhex(text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, text);
    return bytes;
}

fn digest(bytes: []const u8, hex: []const u8) !void {
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "sender wire bytes and rejection boundaries match the Axolotl public segmenter" {
    const fixtures = try load();
    defer fixtures.deinit();
    var output: [512]u8 = undefined;
    for (fixtures.value.send) |case| {
        const input = try unhex(case.payload_hex);
        defer allocator.free(input);
        const result = framing.Sender.init(.reliable, input, .{ .frame_bytes = case.capacity + 1 });
        if (case.@"error") {
            if (result) |_| return error.ExpectedOracleRejection else |_| continue;
        }
        var sender = try result;
        for (case.frames_hex) |expected_hex| {
            const expected = try unhex(expected_hex);
            defer allocator.free(expected);
            try std.testing.expectEqualSlices(u8, expected, (try sender.write(&output)).?);
            try expect(sender.commit());
        }
        try expect(sender.done());
        try equal(null, try sender.write(&output));
    }
}

test "receiver results and reset after malformed fragments match the Axolotl public assembler" {
    const fixtures = try load();
    defer fixtures.deinit();
    var storage: [512]u8 = undefined;
    for (fixtures.value.receive) |case| {
        var receiver = try framing.Receiver.init(if (case.reliable) .reliable else .unreliable, &storage, .{ .message_bytes = case.limit });
        try equal(case.frames_hex.len, case.results.len);
        for (case.frames_hex, case.results, 0..) |frame_hex, expected, index| {
            const frame = try unhex(frame_hex);
            defer allocator.free(frame);
            const result = receiver.accept(frame, @intCast(index));
            if (expected.@"error") {
                if (result) |_| return error.ExpectedOracleRejection else |_| continue;
            }
            if (expected.pending) {
                try equal(null, try result);
            } else {
                const payload = try unhex(expected.payload_hex.?);
                defer allocator.free(payload);
                try std.testing.expectEqualSlices(u8, payload, (try result).?);
            }
        }
    }
}

test "maximum SCTP frame boundaries match hashes from the independent segmenter" {
    const fixtures = try load();
    defer fixtures.deinit();
    const output = try allocator.alloc(u8, framing.max_frame_bytes);
    defer allocator.free(output);
    for (fixtures.value.boundaries) |case| {
        const input = try allocator.alloc(u8, case.length);
        defer allocator.free(input);
        const pattern = [_]u8{ 0, 127, 255, 128 };
        for (input, 0..) |*byte, i| byte.* = pattern[i % pattern.len];
        try digest(input, case.payload_sha256);
        var sender = try framing.Sender.init(.reliable, input, .{});
        for (case.frames) |frame| {
            const actual = (try sender.write(output)).?;
            try equal(frame.length, actual.len);
            try equal(frame.header, actual[0]);
            try digest(actual, frame.sha256);
            try expect(sender.commit());
        }
        try expect(sender.done());
    }
}

test "sender retries preserve bytes and input while queue admission has not committed" {
    var input = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var sender = try framing.Sender.init(.reliable, &input, limits);
    var output: [5]u8 = @splat(9);
    try expectError(error.NoSpace, sender.write(output[0..4]));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9, 9 }, &output);
    try expectError(error.AliasedOutput, sender.write(&input));
    try expectError(error.AliasedOutput, sender.write(std.mem.asBytes(&sender)));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, (try sender.write(&output)).?[1..]);
    const before = output;
    try std.testing.expectEqualSlices(u8, &before, (try sender.write(&output)).?);
    try equal(@as(usize, 0), sender.position);
    try expect(sender.commit());
    try std.testing.expectEqualSlices(u8, &.{ 0, 5, 6 }, (try sender.write(&output)).?);
    try expect(sender.commit());
    try expect(!sender.commit());
    try equal(null, try sender.write(&.{}));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &input);
}

test "sender validates limits and refuses unreliable fragmentation before writing" {
    var bytes: [256]u8 = undefined;
    try expectError(error.UnreliableFragmentation, framing.Sender.init(.unreliable, "abcde", limits));
    try expectError(error.MessageTooLarge, framing.Sender.init(.reliable, &bytes, limits));
    try expectError(error.TooManyFragments, framing.Sender.init(.reliable, &bytes, .{ .frame_bytes = 2 }));
    for ([_]framing.Limits{
        .{ .frame_bytes = 0 },   .{ .frame_bytes = 1 },                        .{ .frame_bytes = std.math.maxInt(usize) },
        .{ .message_bytes = 0 }, .{ .message_bytes = std.math.maxInt(usize) }, .{ .assembly_timeout_ns = 0 },
    }) |invalid| try expectError(error.InvalidLimits, framing.Sender.init(.reliable, "", invalid));
    var empty = try framing.Sender.init(.unreliable, "", limits);
    try expect(empty.done());
}

test "receiver timeout is absolute and checked without new frames or overflowing time" {
    var storage: [16]u8 = undefined;
    var receiver = try framing.Receiver.init(.reliable, &storage, limits);
    try equal(null, try receiver.accept("\x02ab", 0));
    try equal(null, try receiver.accept("\x01cd", 9));
    try expectError(error.AssemblyTimeout, receiver.poll(10));
    try equal(@as(usize, 0), receiver.used);
    try std.testing.expectEqualStrings("x", (try receiver.accept("\x00x", 10)).?);
    try expectError(error.ClockWentBackwards, receiver.poll(9));
    try equal(@as(u64, 10), receiver.last_ns);
    const end = std.math.maxInt(u64);
    try equal(null, try receiver.accept("\x01a", end - 10));
    try receiver.poll(end - 1);
    try expectError(error.AssemblyTimeout, receiver.accept("\x00b", end));
    receiver.close();
    receiver.reset();
    try expectError(error.Closed, receiver.accept("\x00x", end));
}

test "frame and storage budgets reset malformed sequences without partial delivery" {
    var storage: [16]u8 = undefined;
    try expectError(error.InsufficientStorage, framing.Receiver.init(.reliable, storage[0..15], limits));
    var receiver = try framing.Receiver.init(.reliable, &storage, limits);
    try equal(null, try receiver.accept("\x01ab", 0));
    try expectError(error.FrameTooLarge, receiver.accept("\x00abcde", 1));
    try equal(@as(usize, 0), receiver.used);
    try expectError(error.InvalidFrame, receiver.accept("", 2));
    try expectError(error.InvalidFrame, receiver.accept("\x00", 3));
    try equal(null, try receiver.accept("\x02a", 4));
    try expectError(error.UnexpectedCountdown, receiver.accept("\x00b", 5));
    receiver = try framing.Receiver.init(.reliable, &storage, .{ .frame_bytes = 5, .message_bytes = 4 });
    try equal(null, try receiver.accept("\x01abc", 0));
    try expectError(error.MessageTooLarge, receiver.accept("\x00de", 1));
    try std.testing.expectEqualStrings("z", (try receiver.accept("\x00z", 2)).?);
    receiver = try framing.Receiver.init(.unreliable, &storage, limits);
    try expectError(error.UnreliableFragmentation, receiver.accept("\x01a", 0));
}

test "receiver rejects overlapping metadata and borrowed frame storage without mutation" {
    var storage: [16]u8 = @splat(42);
    var receiver = try framing.Receiver.init(.reliable, &storage, limits);
    try equal(null, try receiver.accept("\x01ab", 1));
    const before = storage;
    try expectError(error.AliasedInput, receiver.accept(storage[0..3], 2));
    try expectError(error.AliasedInput, receiver.accept(std.mem.asBytes(&receiver)[0..3], 2));
    try equal(@as(usize, 2), receiver.used);
    try equal(@as(u64, 1), receiver.last_ns);
    try std.testing.expectEqualSlices(u8, &before, &storage);
    receiver.storage = std.mem.asBytes(&receiver);
    try expectError(error.AliasedStorage, receiver.accept("\x00z", 2));
}

test "bounded fragmentation round trips binary messages over many chunk and payload boundaries" {
    var input: [513]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index * 73 + 17);
    var output: [34]u8 = undefined;
    var storage: [513]u8 = undefined;
    for (1..34) |capacity| {
        for (0..input.len + 1) |length| {
            const settings: framing.Limits = .{ .frame_bytes = capacity + 1, .message_bytes = input.len };
            if (length > capacity * framing.max_send_fragments) {
                try expectError(error.TooManyFragments, framing.Sender.init(.reliable, input[0..length], settings));
                continue;
            }
            var sender = try framing.Sender.init(.reliable, input[0..length], settings);
            var receiver = try framing.Receiver.init(.reliable, &storage, settings);
            var count: usize = 0;
            while (try sender.write(&output)) |frame| {
                const result = try receiver.accept(frame, @intCast(count));
                try expect(sender.commit());
                if (sender.done()) {
                    try std.testing.expectEqualSlices(u8, input[0..length], result.?);
                } else try equal(null, result);
                count += 1;
            }
            try equal(if (length == 0) 0 else (length - 1) / capacity + 1, count);
        }
    }
}

fn open(session: *Session, now: u64) !void {
    try session.channelOpened(session.id, .reliable, .{ .ordered = true }, now);
    try session.channelOpened(session.id, .unreliable, .{ .ordered = false, .max_retransmits = 0 }, now);
}

test "session keeps channel buffers independent while reliable fragments are pending" {
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try expectError(error.NotOpen, session.accept(id, .reliable, "\x00x", 0));
    try session.channelOpened(id, .unreliable, .required(.unreliable), 1);
    try equal(Session.State.negotiating, session.state);
    try session.channelOpened(id, .reliable, .required(.reliable), 2);
    try equal(Session.State.open, session.state);
    try equal(null, try session.accept(id, .reliable, "\x01ab", 3));
    const other = (try session.accept(id, .unreliable, "\x00xy", 4)).?;
    try std.testing.expectEqualStrings("abcd", (try session.accept(id, .reliable, "\x00cd", 5)).?);
    try std.testing.expectEqualStrings("xy", other);
    try session.close(id, .requested);
    try session.close(id, .invalid_channel);
    try equal(Session.CloseReason.requested, session.close_reason.?);
    try expectError(error.Closed, session.accept(id, .reliable, "\x00late", 6));
}

test "stale callback identities cannot mutate, close or advance the replacement session clock" {
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try open(&session, 0);
    try equal(null, try session.accept(id, .reliable, "\x01ab", 1));
    var old = id;
    old.generation -= 1;
    var foreign = id;
    foreign.owner += 1;
    var slot = id;
    slot.index += 1;
    for ([_]Session.Id{ old, foreign, slot }) |stale| {
        try expectError(error.StaleSession, session.accept(stale, .reliable, "\xffignored", std.math.maxInt(u64)));
        try expectError(error.StaleSession, session.close(stale, .requested));
        try expectError(error.StaleSession, session.channelOpened(stale, .reliable, .required(.reliable), 0));
    }
    try equal(@as(u64, 1), session.last_ns);
    try equal(@as(usize, 2), session.receivers[0].used);
    try std.testing.expectEqualStrings("abcd", (try session.accept(id, .reliable, "\x00cd", 2)).?);
}

test "same-session framing failure closes both channels and discards incomplete state" {
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try open(&session, 0);
    try equal(null, try session.accept(id, .reliable, "\x02ab", 1));
    try expectError(error.UnreliableFragmentation, session.accept(id, .unreliable, "\x01x", 2));
    try equal(Session.State.closed, session.state);
    try equal(Session.CloseReason.framing_error, session.close_reason.?);
    for (session.receivers) |receiver| {
        try expect(receiver.closed);
        try equal(@as(usize, 0), receiver.used);
    }
}

test "session negotiation and assembly expire at exact elapsed deadlines" {
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    const end = std.math.maxInt(u64);
    var session = try Session.init(id, &reliable, &unreliable, limits, end - 10, 10);
    try session.poll(end - 1);
    try expectError(error.NegotiationTimeout, session.channelOpened(id, .reliable, .required(.reliable), end));
    try equal(Session.CloseReason.negotiation_timeout, session.close_reason.?);
    session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try open(&session, 0);
    try equal(null, try session.accept(id, .reliable, "\x02a", 1));
    try equal(null, try session.accept(id, .reliable, "\x01b", 10));
    try expectError(error.AssemblyTimeout, session.poll(11));
    try equal(Session.CloseReason.assembly_timeout, session.close_reason.?);
}

test "channel configuration, exact labels and duplicate opens are validated" {
    try std.testing.expectEqualStrings("ReliableDataChannel", framing.Channel.reliable.label());
    try std.testing.expectEqualStrings("UnreliableDataChannel", framing.Channel.unreliable.label());
    try equal(framing.Channel.reliable, framing.Channel.fromLabel("ReliableDataChannel").?);
    try equal(framing.Channel.unreliable, framing.Channel.fromLabel("UnreliableDataChannel").?);
    try equal(null, framing.Channel.fromLabel("reliabledatachannel"));
    try equal(null, framing.Channel.fromLabel("UnknownDataChannel"));
    try equal(null, framing.Channel.fromLabel("ReliableDataChannel\x00"));
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    for ([_]Session.ChannelOptions{
        .{ .ordered = false },                              .{ .ordered = false, .max_retransmits = 1 },
        .{ .ordered = false, .max_packet_lifetime_ms = 1 }, .{ .ordered = true, .max_retransmits = 0 },
    }) |options| {
        var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
        try expectError(error.InvalidChannel, session.channelOpened(id, .unreliable, options, 0));
        try equal(Session.State.closed, session.state);
    }
    var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try session.channelOpened(id, .reliable, .required(.reliable), 0);
    try expectError(error.InvalidChannel, session.channelOpened(id, .reliable, .required(.reliable), 0));
    try equal(Session.CloseReason.invalid_channel, session.close_reason.?);
}

test "session initialization and local storage errors preserve ownership" {
    var reliable: [16]u8 = undefined;
    var unreliable: [4]u8 = undefined;
    try expectError(error.InvalidIdentity, Session.init(.{ .owner = 0, .index = 0, .generation = 1 }, &reliable, &unreliable, limits, 0, 1));
    try expectError(error.InvalidIdentity, Session.init(.{ .owner = 1, .index = 0, .generation = 0 }, &reliable, &unreliable, limits, 0, 1));
    try expectError(error.InvalidTimeout, Session.init(id, &reliable, &unreliable, limits, 0, 0));
    try expectError(error.AliasedStorage, Session.init(id, &reliable, reliable[0..4], limits, 0, 1));
    var session = try Session.init(id, &reliable, &unreliable, limits, 0, 50);
    try open(&session, 2);
    try expectError(error.ClockWentBackwards, session.accept(id, .reliable, "\x00x", 1));
    try equal(@as(u64, 2), session.last_ns);
    try expectError(error.AliasedInput, session.accept(id, .reliable, &unreliable, 3));
    try equal(@as(u64, 2), session.last_ns);
    session.receivers[0].storage = std.mem.asBytes(&session);
    try expectError(error.AliasedStorage, session.accept(id, .reliable, "\x00x", 3));
    try equal(Session.State.open, session.state);
}
