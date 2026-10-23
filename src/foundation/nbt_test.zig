const std = @import("std");
const nbt = @import("nbt.zig");
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;

const formats = [_]nbt.Format{ .big_endian, .little_endian, .network };
const all_tags = [_][]const u8{
    @embedFile("fixtures/nbt/all-tags.big.nbt"),
    @embedFile("fixtures/nbt/all-tags.little.nbt"),
    @embedFile("fixtures/nbt/all-tags.network.nbt"),
};
const scalars = [_][]const u8{
    @embedFile("fixtures/nbt/scalar.big.nbt"),
    @embedFile("fixtures/nbt/scalar.little.nbt"),
    @embedFile("fixtures/nbt/scalar.network.nbt"),
};
const nested_lists = [_][]const u8{
    @embedFile("fixtures/nbt/nested-lists.big.nbt"),
    @embedFile("fixtures/nbt/nested-lists.little.nbt"),
    @embedFile("fixtures/nbt/nested-lists.network.nbt"),
};

test "pinned PMMP oracle fixtures decode values and reproduce exact bytes" {
    for (formats, all_tags) |format, bytes| {
        var document = try nbt.decode(allocator, bytes, format, .{});
        defer document.deinit();
        const nodes = document.nodes;
        try equal(17, nodes.len);
        try std.testing.expectEqualStrings("root", nodes[0].name);
        try equal(13, nodes[0].value.compound.count);
        try equal(-128, nodes[1].value.byte);
        try equal(-32768, nodes[2].value.short);
        try equal(std.math.minInt(i32), nodes[3].value.int);
        try equal(std.math.minInt(i64), nodes[4].value.long);
        try equal(@as(f32, 1.5), nodes[5].value.float);
        try equal(@as(f64, -2.25), nodes[6].value.double);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0x7f, 0x80, 0xff }, nodes[7].value.byte_array);
        try std.testing.expectEqualStrings("\x00\xc3\xa9\xff", nodes[8].value.string);
        try std.testing.expectEqualSlices(i32, &.{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) }, nodes[9].value.int_array);
        try equal(nbt.Type.long, nodes[10].value.list.element_type);
        try equal(std.math.minInt(i64), nodes[11].value.long);
        try equal(std.math.maxInt(i64), nodes[12].value.long);
        try equal(13, nodes[10].next_sibling.?);
        try std.testing.expectEqualStrings("ok", nodes[14].value.string);
        try equal(nbt.Type.end, nodes[15].value.list.element_type);
        try equal(nbt.Type.short, nodes[16].value.list.element_type);
        try equal(try nbt.encodedSize(nodes, format, .{}), bytes.len);
        var output: [1024]u8 = undefined;
        try std.testing.expectEqualSlices(u8, bytes, try nbt.encode(&output, nodes, format, .{}));
        // Check a different wire representation, not just a paired round trip.
        try std.testing.expectEqualSlices(u8, all_tags[2], try nbt.encode(&output, nodes, .network, .{}));
    }
}

test "scalar roots and nested lists match upstream fixtures" {
    for (formats, scalars, nested_lists) |format, scalar, nested| {
        var document = try nbt.decode(allocator, scalar, format, .{});
        defer document.deinit();
        try equal(std.math.maxInt(i64), document.nodes[0].value.long);
        try std.testing.expectEqualStrings("r", document.nodes[0].name);
        var lists = try nbt.decode(allocator, nested, format, .{});
        defer lists.deinit();
        try equal(5, lists.nodes.len);
        try equal(-1, lists.nodes[2].value.int);
        try equal(128, lists.nodes[3].value.int);
        try equal(4, lists.nodes[1].next_sibling.?);
        try equal(nbt.Type.int, lists.nodes[4].value.list.element_type);
        var output: [128]u8 = undefined;
        try std.testing.expectEqualSlices(u8, nested, try nbt.encode(&output, lists.nodes, format, .{}));
    }
}

test "every truncated fixture prefix fails before allocating" {
    var empty_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty_storage);
    for (formats, all_tags) |format, bytes| {
        for (0..bytes.len) |length| {
            try expectError(error.UnexpectedEnd, nbt.decode(fixed.allocator(), bytes[0..length], format, .{}));
        }
    }
}

test "tag IDs lengths and framing reject malformed data" {
    const cases = [_]struct { bytes: []const u8, format: nbt.Format = .little_endian, err: nbt.Error }{
        .{ .bytes = &.{0}, .err = error.UnexpectedEndTag },
        .{ .bytes = &.{12}, .err = error.UnsupportedTag },
        .{ .bytes = &.{13}, .err = error.UnknownTag },
        .{ .bytes = &.{ 7, 0, 0, 0xff, 0xff, 0xff, 0xff }, .err = error.NegativeLength },
        .{ .bytes = &.{ 9, 0, 0, 1, 0xff, 0xff, 0xff, 0xff }, .err = error.NegativeLength },
        .{ .bytes = &.{ 11, 0, 0, 0xff, 0xff, 0xff, 0xff }, .err = error.NegativeLength },
        .{ .bytes = &.{ 9, 0, 0, 0, 1, 0, 0, 0 }, .err = error.NonEmptyEndList },
        .{ .bytes = &.{ 9, 0, 0, 0xff, 0, 0, 0, 0 }, .err = error.UnknownTag },
        .{ .bytes = &.{ 8, 0, 0, 0, 0x80 }, .err = error.StringTooLong },
        .{ .bytes = &.{ 1, 0, 0, 0, 0 }, .err = error.TrailingData },
        .{ .bytes = &.{ 3, 0, 0x80, 0 }, .format = .network, .err = error.NonCanonicalVarInt },
        .{ .bytes = &.{ 8, 0x80, 0 }, .format = .network, .err = error.NonCanonicalVarInt },
        .{ .bytes = &.{ 3, 0, 0xff, 0xff, 0xff, 0xff, 0x10 }, .format = .network, .err = error.VarIntOverflow },
        .{ .bytes = &.{ 7, 0, 1 }, .format = .network, .err = error.NegativeLength },
    };
    for (cases) |case| try expectError(case.err, nbt.decode(allocator, case.bytes, case.format, .{}));
}

test "all resource budgets enforce their exact boundaries" {
    const bytes = all_tags[1];
    var document = try nbt.decode(allocator, bytes, .little_endian, .{});
    defer document.deinit();
    const exact_memory = document.nodes.len * @sizeOf(nbt.Node) + 5 * @sizeOf(i32);
    var limits: nbt.Limits = .{ .max_bytes = bytes.len, .max_depth = 3, .max_nodes = 17, .max_collection_len = 13, .max_string_bytes = 6, .max_allocated_bytes = exact_memory };
    var exact = try nbt.decode(allocator, bytes, .little_endian, limits);
    exact.deinit();
    limits.max_bytes -= 1;
    try expectError(error.ByteLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_depth = 2 };
    try expectError(error.DepthLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_nodes = 16 };
    try expectError(error.NodeLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_collection_len = 12 };
    try expectError(error.CollectionLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_string_bytes = 5 };
    try expectError(error.StringTooLong, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_allocated_bytes = exact_memory - 1 };
    try expectError(error.AllocationLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    limits = .{ .max_work = 0 };
    try expectError(error.WorkLimit, nbt.decode(allocator, bytes, .little_endian, limits));
    for ([_]nbt.Limits{ .{ .max_depth = 0 }, .{ .max_depth = 65 }, .{ .max_string_bytes = 32768 } }) |invalid|
        try expectError(error.InvalidLimits, nbt.decode(allocator, bytes, .little_endian, invalid));
    try expectError(error.CollectionLimit, nbt.decode(allocator, &.{ 7, 0, 0, 0xff, 0xff, 0xff, 0x7f }, .little_endian, .{}));
}

fn allocationCase(failing: std.mem.Allocator) !void {
    for (formats, all_tags) |format, bytes| {
        var document = try nbt.decode(failing, bytes, format, .{});
        document.deinit();
    }
}

test "allocation failures release partial documents" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}

test "depth 64 and string 32767 boundaries work in every format" {
    // A chain of compounds followed by their end markers, built without the encoder.
    for (formats) |format| {
        var input: [65 * 4]u8 = @splat(0);
        var boundary: [64 * 4]u8 = @splat(0);
        const header_size: usize = if (format == .network) 2 else 3;
        for (0..65) |i| input[i * header_size] = 10;
        for (0..64) |i| boundary[i * header_size] = 10;
        var valid = try nbt.decode(allocator, boundary[0 .. 64 * (header_size + 1)], format, .{});
        valid.deinit();
        try expectError(error.DepthLimit, nbt.decode(allocator, input[0 .. 65 * (header_size + 1)], format, .{}));
    }

    const text = try allocator.alloc(u8, 32768);
    defer allocator.free(text);
    @memset(text, 'x');
    const output = try allocator.alloc(u8, 32800);
    defer allocator.free(output);
    for (formats) |format| {
        var nodes = [_]nbt.Node{.{ .value = .{ .string = text[0..32767] } }};
        const bytes = try nbt.encode(output, &nodes, format, .{});
        var document = try nbt.decode(allocator, bytes, format, .{});
        defer document.deinit();
        try equal(32767, document.nodes[0].value.string.len);
        nodes[0].value.string = text;
        try expectError(error.StringTooLong, nbt.encode(output, &nodes, format, .{}));
    }
}

test "encoder enforces budgets and rejects each broken child contract" {
    const invalid_trees = [_][]const nbt.Node{
        &.{},
        &.{.{ .value = .{ .byte = 1 }, .next_sibling = 0 }},
        &.{ .{ .value = .{ .byte = 1 } }, .{ .value = .{ .byte = 2 } } },
        &.{.{ .value = .{ .compound = .{ .first = 1, .count = 1 } } }},
        &.{.{ .value = .{ .compound = .{ .count = 1 } } }},
        &.{ .{ .value = .{ .compound = .{ .first = 1 } } }, .{ .value = .{ .byte = 1 } } },
        &.{ .{ .value = .{ .compound = .{ .first = 1, .count = 2 } } }, .{ .value = .{ .byte = 1 }, .next_sibling = 1 } },
        &.{ .{ .value = .{ .list = .{ .element_type = .int, .children = .{ .first = 1, .count = 1 } } } }, .{ .value = .{ .byte = 1 } } },
        &.{ .{ .value = .{ .list = .{ .element_type = .byte, .children = .{ .first = 1, .count = 1 } } } }, .{ .name = "named", .value = .{ .byte = 1 } } },
    };
    var output: [1024]u8 = @splat(0xaa);
    const original = output;
    for (invalid_trees) |nodes| try expectError(error.InvalidTree, nbt.encode(&output, nodes, .little_endian, .{}));
    var document = try nbt.decode(allocator, all_tags[1], .little_endian, .{});
    defer document.deinit();
    try expectError(error.ByteLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_bytes = all_tags[1].len - 1 }));
    try expectError(error.NodeLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_nodes = 16 }));
    try expectError(error.CollectionLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_collection_len = 12 }));
    try expectError(error.AllocationLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_allocated_bytes = 0 }));
    try std.testing.expectEqualSlices(u8, &original, &output);
    const scalar = [_]nbt.Node{.{ .value = .{ .byte = 1 } }};
    const bytes = try nbt.encode(&output, &scalar, .little_endian, .{ .max_work = 1 });
    var exact = try nbt.decode(allocator, bytes, .little_endian, .{ .max_work = 1 });
    exact.deinit();
}

test "failed encodes preserve output and reject invalid trees" {
    var output: [1024]u8 = @splat(0xaa);
    const original = output;
    var document = try nbt.decode(allocator, all_tags[1], .little_endian, .{});
    defer document.deinit();
    try expectError(error.NoSpace, nbt.encode(output[0..1], document.nodes, .little_endian, .{}));
    try expectError(error.DepthLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_depth = 2 }));
    try expectError(error.WorkLimit, nbt.encode(&output, document.nodes, .little_endian, .{ .max_work = 0 }));
    const invalid = [_]nbt.Node{.{ .value = .{ .compound = .{ .first = 0, .count = 1 } } }};
    try expectError(error.InvalidTree, nbt.encode(&output, &invalid, .little_endian, .{}));
    const end = [_]nbt.Node{.{ .value = .end }};
    try expectError(error.UnexpectedEndTag, nbt.encode(&output, &end, .little_endian, .{}));
    try std.testing.expectEqualSlices(u8, &original, &output);
}

test "encoder rejects overlapping borrowed input before mutation" {
    var bytes: [all_tags[1].len]u8 = all_tags[1].*;
    const original = bytes;
    var document = try nbt.decode(allocator, &bytes, .little_endian, .{});
    defer document.deinit();
    try expectError(error.OverlappingOutput, nbt.encode(&bytes, document.nodes, .little_endian, .{}));
    try std.testing.expectEqualSlices(u8, &original, &bytes);
}

test "encoder rejects overlap with node string byte and integer storage" {
    var output: [128]u8 align(@alignOf(nbt.Node)) = @splat(0xaa);
    const original = output;
    for ([_]nbt.Value{ .{ .string = output[2..4] }, .{ .byte_array = output[2..4] }, .{ .int_array = std.mem.bytesAsSlice(i32, output[0..8]) } }) |value| {
        const node = [_]nbt.Node{.{ .value = value }};
        try expectError(error.OverlappingOutput, nbt.encode(&output, &node, .little_endian, .{}));
        try std.testing.expectEqualSlices(u8, &original, &output);
    }
    var nodes = [_]nbt.Node{.{ .value = .{ .byte = 0 } }};
    try expectError(error.OverlappingOutput, nbt.encode(std.mem.sliceAsBytes(&nodes), &nodes, .little_endian, .{}));
    const end_list = [_]nbt.Node{.{ .value = .{ .list = .{ .element_type = .end, .children = .{ .first = 0, .count = 1 } } } }};
    try expectError(error.NonEmptyEndList, nbt.encode(&output, &end_list, .little_endian, .{}));
}

test "float bits raw strings duplicate names and empty containers are preserved" {
    const bytes = [_]u8{ 10, 0, 0, 5, 1, 0, 'x', 1, 0, 0xc0, 0x7f, 6, 1, 0, 'x', 0, 0, 0, 0, 0, 0, 0, 0x80, 10, 0, 0, 0, 0 };
    var document = try nbt.decode(allocator, &bytes, .little_endian, .{});
    defer document.deinit();
    try equal(@as(u32, 0x7fc00001), @as(u32, @bitCast(document.nodes[1].value.float)));
    try equal(@as(u64, 0x8000000000000000), @as(u64, @bitCast(document.nodes[2].value.double)));
    try equal(0, document.nodes[3].value.compound.count);
    var output: [128]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try nbt.encode(&output, document.nodes, .little_endian, .{}));
}

test "bounded malformed corpus never leaks and accepted trees re-encode" {
    var prng = std.Random.DefaultPrng.init(0x5348554c565952);
    const random = prng.random();
    var input: [256]u8 = undefined;
    var output: [1024]u8 = undefined;
    const limits: nbt.Limits = .{ .max_nodes = 64, .max_collection_len = 64, .max_depth = 8, .max_work = 4096, .max_allocated_bytes = 8192 };
    var accepted_mutations: usize = 0;
    for (0..2048) |iteration| {
        random.bytes(&input);
        const length = random.intRangeAtMost(usize, 0, input.len);
        const format = formats[iteration % formats.len];
        var document = nbt.decode(allocator, input[0..length], format, limits) catch continue;
        defer document.deinit();
        try std.testing.expectEqualSlices(u8, input[0..length], try nbt.encode(&output, document.nodes, format, limits));
    }
    // Mutations reach deeper structures than random tag IDs alone.
    for (formats, all_tags) |format, fixture| {
        for (0..fixture.len) |index| {
            @memcpy(input[0..fixture.len], fixture);
            input[index] ^= 0xff;
            var document = nbt.decode(allocator, input[0..fixture.len], format, limits) catch continue;
            defer document.deinit();
            accepted_mutations += 1;
            try std.testing.expectEqualSlices(u8, input[0..fixture.len], try nbt.encode(&output, document.nodes, format, limits));
        }
    }
    try std.testing.expect(accepted_mutations > 0);
}
