const std = @import("std");
const Registry = @import("Registry.zig").Registry;
const Row = @import("Registry.zig").Row;
const Items = @import("catalog.zig").Items;
const Query = struct { key: ?[]const u8 = null, network_id: ?i16 = null };
const Answer = struct { found: bool, key: ?[]const u8, network_id: ?i16 };
const Input = struct { synthetic_entries: []const Row, synthetic_queries: []const Query, source_queries: []const Query };
const Expected = struct {
    source_entry_count: usize,
    source_mapping_sha256: []const u8,
    synthetic_answers: []const Answer,
    source_answers: []const Answer,
};
const Synthetic = Registry(.item, i16, &.{
    .{ .key = "shulvyr:alpha", .network_id = -32768 },
    .{ .key = "shulvyr:beta", .network_id = -1 },
    .{ .key = "shulvyr:delta", .network_id = 0 },
    .{ .key = "shulvyr:epsilon", .network_id = 1 },
    .{ .key = "shulvyr:gamma", .network_id = 32767 },
}, &.{ 0, 1, 2, 3, 4 });

fn checkQueries(comptime Catalog: type, queries: []const Query, answers: []const Answer) !void {
    try std.testing.expectEqual(queries.len, answers.len);
    for (queries, answers) |query, expected| {
        const id = if (query.key) |key| Catalog.resolve(key) else Catalog.fromNetwork(.{ .value = query.network_id.? });
        try std.testing.expectEqual(expected.found, id != null);
        if (id) |found| {
            const entry = Catalog.get(found).?;
            try std.testing.expectEqualStrings(expected.key.?, entry.key.bytes);
            try std.testing.expectEqual(expected.network_id.?, entry.network_id.value);
        } else {
            try std.testing.expectEqual(null, expected.key);
            try std.testing.expectEqual(null, expected.network_id);
        }
    }
}

test "source and synthetic lookups match the upstream dictionary oracle" {
    const input = try std.json.parseFromSlice(Input, std.testing.allocator, @embedFile("fixtures/input.json"), .{});
    defer input.deinit();
    const expected = try std.json.parseFromSlice(Expected, std.testing.allocator, @embedFile("fixtures/expected.json"), .{});
    defer expected.deinit();
    try std.testing.expectEqual(Synthetic.count, input.value.synthetic_entries.len);
    for (input.value.synthetic_entries) |row| {
        try std.testing.expectEqual(row.network_id, Synthetic.get(Synthetic.resolve(row.key).?).?.network_id.value);
    }
    try checkQueries(Items, input.value.source_queries, expected.value.source_answers);
    try checkQueries(Synthetic, input.value.synthetic_queries, expected.value.synthetic_answers);

    try std.testing.expectEqual(Items.count, expected.value.source_entry_count);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (0..Items.count) |index| {
        const entry = Items.get(@fromBackingInt(@intCast(index))).?;
        hash.update(entry.key.bytes);
        var storage: [16]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&storage, "\t{d}\n", .{entry.network_id.value});
        hash.update(suffix);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var expected_digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, expected.value.source_mapping_sha256);
    try std.testing.expectEqualSlices(u8, &expected_digest, &digest);
}
