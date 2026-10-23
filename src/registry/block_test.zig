const std = @import("std");
const BlockState = @import("BlockState.zig");
const nbt = @import("../foundation/nbt.zig");
const equal = std.testing.expectEqual;
const allocator = std.testing.allocator;
const fixtures = blk: {
    var result: [11][]const u8 = undefined;
    for (0..result.len) |index| result[index] = @embedFile(std.fmt.comptimePrint("fixtures/blocks/case-{d}.network.nbt", .{index}));
    break :blk result;
};
const Expected = struct {
    cases: []const struct {
        file: []const u8,
        accepted: bool,
        state: ?struct {
            name: []const u8,
            version: i32,
            properties: []const struct {
                name: []const u8,
                kind: enum { byte, int, string },
                number: ?i32,
                text: ?[]const u8,
            },
        },
        property_key_hex: ?[]const u8,
    },
    equalities: []const struct { a: usize, b: usize, equal: bool },
    palette: struct { roots: usize, names: usize, properties: usize, versions: []const i32, semantic_sha256: []const u8 },
};

fn load() !std.json.Parsed(Expected) {
    return std.json.parseFromSlice(Expected, allocator, @embedFile("fixtures/blocks/expected.json"), .{});
}

test "block schema identity and property encoding match current upstream oracles" {
    const expected = try load();
    defer expected.deinit();
    try equal(fixtures.len, expected.value.cases.len);
    var states: [fixtures.len]?BlockState = @splat(null);
    for (fixtures, expected.value.cases, 0..) |bytes, case, index| {
        if (!case.accepted) {
            _ = BlockState.decode(allocator, bytes, .network, .{}) catch |err| switch (err) {
                error.UnknownField, error.InvalidBlockState => continue,
                else => return err,
            };
            return error.ExpectedBlockSchemaRejection;
        }
        const state = try BlockState.decode(allocator, bytes, .network, .{});
        states[index] = state;
        const answer = case.state.?;
        try std.testing.expectEqualStrings(answer.name, state.key.bytes);
        try equal(answer.version, state.version);
        try equal(answer.properties.len, state.properties().len);
        for (answer.properties, state.properties()) |wanted, actual| {
            try std.testing.expectEqualStrings(wanted.name, actual.name);
            switch (wanted.kind) {
                .byte => try equal(wanted.number.?, actual.value.byte),
                .int => try equal(wanted.number.?, actual.value.int),
                .string => try std.testing.expectEqualStrings(wanted.text.?, actual.value.string),
            }
            try std.testing.expect(actual.value.eql(state.getProperty(wanted.name).?));
        }
        try equal(null, state.getProperty("missing_fixture_property"));
        var output: [16 * 1024]u8 = undefined;
        var decoded_key: [16 * 1024]u8 = undefined;
        const oracle_key = try std.fmt.hexToBytes(&decoded_key, case.property_key_hex.?);
        try std.testing.expectEqualSlices(u8, oracle_key, try state.encodeProperties(&output));
    }
    for (expected.value.equalities) |case| try equal(case.equal, states[case.a].?.eql(&states[case.b].?));
}

test "complete canonical palette matches upstream semantic hash and counts" {
    const expected = try load();
    defer expected.deinit();
    const palette = @import("bedrock_data").canonical_block_states;
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    var semantic: std.crypto.hash.sha2.Sha256 = .init(.{});
    var offset: usize = 0;
    var count: usize = 0;
    var property_count: usize = 0;
    var output: [16 * 1024]u8 = undefined;
    while (offset < palette.len) {
        if (count == 65_536) return error.PaletteRootLimit;
        const prefix = try BlockState.decodePrefix(allocator, palette[offset..], .network, .{});
        try std.testing.expect(prefix.bytes_read > 0);
        offset += prefix.bytes_read;
        count += 1;
        property_count += prefix.state.properties().len;
        try names.put(prefix.state.key.bytes, {});
        try std.testing.expect(std.mem.indexOfScalar(i32, expected.value.palette.versions, prefix.state.version) != null);
        const encoded_properties = try prefix.state.encodeProperties(&output);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(prefix.state.key.bytes.len), .little);
        semantic.update(&length);
        semantic.update(prefix.state.key.bytes);
        std.mem.writeInt(u32, &length, @intCast(encoded_properties.len), .little);
        semantic.update(&length);
        semantic.update(encoded_properties);
    }
    try equal(palette.len, offset);
    try equal(expected.value.palette.roots, count);
    try equal(expected.value.palette.properties, property_count);
    try equal(expected.value.palette.names, names.count());
    var digest: [32]u8 = undefined;
    semantic.final(&digest);
    var oracle: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&oracle, expected.value.palette.semantic_sha256);
    try std.testing.expectEqualSlices(u8, &oracle, &digest);
}

fn basicNodes() [5]nbt.Node {
    return .{
        .{ .value = .{ .compound = .{ .first = 1, .count = 3 } } },
        .{ .name = "name", .value = .{ .string = "minecraft:stone" }, .next_sibling = 2 },
        .{ .name = "states", .value = .{ .compound = .{ .first = 3, .count = 1 } }, .next_sibling = 4 },
        .{ .name = "value", .value = .{ .int = 0 } },
        .{ .name = "version", .value = .{ .int = 1 } },
    };
}

fn rejected(nodes: []const nbt.Node, expected: BlockState.Error) !void {
    var output: [16 * 1024]u8 = undefined;
    const bytes = try nbt.encode(&output, nodes, .network, .{});
    try std.testing.expectError(expected, BlockState.decode(allocator, bytes, .network, .{ .codec = .{ .max_string_bytes = 512 } }));
}

test "block schema rejects duplicates unsupported property tags and invalid names" {
    var nodes = basicNodes();
    nodes[4] = .{ .name = "name", .value = .{ .string = "minecraft:dirt" } };
    try rejected(&nodes, error.DuplicateField);
    nodes = basicNodes();
    nodes[1].value = .{ .int = 1 };
    try rejected(&nodes, error.InvalidBlockState);
    nodes = basicNodes();
    nodes[1].value = .{ .string = "stone" };
    try rejected(&nodes, error.InvalidResourceKey);
    nodes = basicNodes();
    nodes[3].value = .{ .short = 1 };
    try rejected(&nodes, error.UnsupportedPropertyType);
    var duplicate: [6]nbt.Node = undefined;
    @memcpy(duplicate[0..4], basicNodes()[0..4]);
    duplicate[2].value.compound.count = 2;
    duplicate[2].next_sibling = 5;
    duplicate[3].next_sibling = 4;
    duplicate[4] = duplicate[3];
    duplicate[4].next_sibling = null;
    duplicate[5] = basicNodes()[4];
    try rejected(&duplicate, error.DuplicateProperty);
    nodes = basicNodes();
    var long_name: [BlockState.max_property_name_bytes + 1]u8 = @splat('x');
    nodes[3].name = &long_name;
    try rejected(&nodes, error.PropertyLimit);
    nodes = basicNodes();
    var long_string: [BlockState.max_property_string_bytes + 1]u8 = @splat('x');
    nodes[3].value = .{ .string = &long_string };
    try rejected(&nodes, error.PropertyLimit);
}

fn allocationCase(failing: std.mem.Allocator) !void {
    const state = try BlockState.decode(failing, fixtures[1], .network, .{});
    try equal(3, state.properties().len);
}

test "block limits truncation allocation failure and output errors preserve ownership" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
    for (0..fixtures[1].len) |length| try std.testing.expectError(error.UnexpectedEnd, BlockState.decode(std.testing.failing_allocator, fixtures[1][0..length], .network, .{}));
    try std.testing.expectError(error.InvalidLimits, BlockState.decode(std.testing.failing_allocator, fixtures[0], .network, .{ .property_count = 33 }));
    try std.testing.expectError(error.PropertyLimit, BlockState.decode(allocator, fixtures[1], .network, .{ .property_count = 2 }));
    var input: [fixtures[1].len]u8 = fixtures[1][0..fixtures[1].len].*;
    const state = try BlockState.decode(allocator, &input, .network, .{});
    try std.testing.expectError(error.OverlappingOutput, state.encodeProperties(&input));
    try std.testing.expectEqualSlices(u8, fixtures[1], &input);
    var short: [1]u8 = .{0xa5};
    try std.testing.expectError(error.NoSpace, state.encodeProperties(&short));
    try equal(@as(u8, 0xa5), short[0]);
}

test "block property strings preserve raw bytes across codec formats" {
    var nodes = basicNodes();
    nodes[3] = .{ .name = "v", .value = .{ .string = "\x00\xff" } };
    for ([_]nbt.Format{ .big_endian, .little_endian, .network }) |format| {
        var wire: [512]u8 = undefined;
        const input = try nbt.encode(&wire, &nodes, format, .{});
        const state = try BlockState.decode(allocator, input, format, .{});
        try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, state.getProperty("v").?.string);
        var key: [64]u8 = undefined;
        const expected = [_]u8{ 10, 0, 0, 8, 1, 0, 'v', 2, 0, 0, 255, 0 };
        try std.testing.expectEqualSlices(u8, &expected, try state.encodeProperties(&key));
    }
}

test "block property capacity accepts its boundary without truncation" {
    var nodes: [BlockState.max_properties + 4]nbt.Node = undefined;
    @memcpy(nodes[0..3], basicNodes()[0..3]);
    nodes[2].value.compound = .{ .first = 3, .count = BlockState.max_properties };
    nodes[2].next_sibling = nodes.len - 1;
    var names: [BlockState.max_properties][8]u8 = undefined;
    for (0..BlockState.max_properties) |index| {
        nodes[index + 3] = .{
            .name = try std.fmt.bufPrint(&names[index], "p{d}", .{index}),
            .value = .{ .int = @intCast(index) },
            .next_sibling = if (index + 1 < BlockState.max_properties) @intCast(index + 4) else null,
        };
    }
    nodes[nodes.len - 1] = basicNodes()[4];
    var wire: [4096]u8 = undefined;
    const bytes = try nbt.encode(&wire, &nodes, .network, .{});
    const state = try BlockState.decode(allocator, bytes, .network, .{});
    try equal(BlockState.max_properties, state.properties().len);
    try equal(@as(i32, 31), state.getProperty("p31").?.int);
}
