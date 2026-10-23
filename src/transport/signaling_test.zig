const std = @import("std");
const Signal = @import("Signal.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;

const Fixtures = struct {
    cases: []const struct {
        name: []const u8,
        wire_hex: []const u8,
        kind: ?[]const u8 = null,
        connection_id: ?[]const u8 = null,
        data_hex: ?[]const u8 = null,
        encoded_hex: ?[]const u8 = null,
        @"error": bool = false,
    },
};

fn unhex(text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, text);
    return bytes;
}

test "signaling parse and canonical output match the public Axolotl Signal oracle" {
    const fixtures = try std.json.parseFromSlice(Fixtures, allocator, @embedFile("fixtures/signaling.json"), .{ .ignore_unknown_fields = true });
    defer fixtures.deinit();
    try equal(@as(usize, 30), fixtures.value.cases.len);
    var output: [1024]u8 = undefined;
    for (fixtures.value.cases) |case| {
        const input = try unhex(case.wire_hex);
        defer allocator.free(input);
        const parsed = Signal.parse(input, .{});
        if (case.@"error") {
            if (parsed) |_| return error.ExpectedOracleRejection else |_| continue;
        }
        const signal = try parsed;
        try std.testing.expectEqualStrings(case.kind.?, @tagName(signal.kind));
        try equal(try std.fmt.parseInt(u64, case.connection_id.?, 10), signal.connection_id);
        const data = try unhex(case.data_hex.?);
        defer allocator.free(data);
        try std.testing.expectEqualSlices(u8, data, signal.data);
        try expect(@intFromPtr(signal.data.ptr) >= @intFromPtr(input.ptr));
        try expect(@intFromPtr(signal.data.ptr) + signal.data.len <= @intFromPtr(input.ptr) + input.len);
        const encoded = try unhex(case.encoded_hex.?);
        defer allocator.free(encoded);
        try std.testing.expectEqualSlices(u8, encoded, try signal.write(&output, .{}));
    }
}

test "signaling bounds reject excess text and data with explicit zero-data policy" {
    const input = "CONNECTREQUEST 8 ab";
    try expectError(error.InvalidLimits, Signal.parse(input, .{ .text_bytes = 0 }));
    try expectError(error.InvalidLimits, Signal.parse(input, .{ .text_bytes = 10, .data_bytes = 11 }));
    try expectError(error.TextTooLong, Signal.parse(input, .{ .text_bytes = input.len - 1, .data_bytes = 2 }));
    try expectError(error.DataTooLong, Signal.parse(input, .{ .text_bytes = input.len, .data_bytes = 1 }));
    const exact = try Signal.parse(input, .{ .text_bytes = input.len, .data_bytes = 2 });
    try equal(@as(u64, 8), exact.connection_id);
    try expectError(error.DataTooLong, Signal.parse(input, .{ .data_bytes = 0 }));
    try equal(@as(usize, 0), (try Signal.parse("CONNECTREQUEST 8 ", .{ .data_bytes = 0 })).data.len);
    try expectError(error.ConnectionIdOverflow, Signal.parse("CONNECTREQUEST 18446744073709551616 x", .{}));
    try expectError(error.InvalidConnectionId, Signal.parse("CONNECTREQUEST -1 x", .{}));
}

test "signaling write preflights size limits and borrowed-storage overlap" {
    var output: [128]u8 = @splat(0xa5);
    const before = output;
    const signal = try Signal.parse("CONNECTREQUEST 0008suffix ab", .{});
    try expectError(error.InvalidLimits, signal.write(&output, .{ .text_bytes = 0 }));
    try expectError(error.DataTooLong, signal.write(&output, .{ .data_bytes = 1 }));
    try expectError(error.TextTooLong, signal.write(&output, .{ .text_bytes = 16, .data_bytes = 2 }));
    try expectError(error.NoSpace, signal.write(output[0..17], .{}));
    try std.testing.expectEqualSlices(u8, &before, &output);
    var alias = Signal{ .kind = .CONNECTREQUEST, .connection_id = 8, .data = output[10..20] };
    try expectError(error.AliasedBuffer, alias.write(&output, .{}));
    try std.testing.expectEqualSlices(u8, &before, &output);
    try expectError(error.AliasedBuffer, alias.write(std.mem.asBytes(&alias), .{}));
    try std.testing.expectEqualStrings("CONNECTREQUEST 8 ab", try signal.write(output[0..19], .{}));
}
