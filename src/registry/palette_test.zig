const std = @import("std");
const BlockPalette = @import("BlockPalette.zig");
const BlockState = @import("BlockState.zig");
const data = @import("bedrock_data");
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const allocator = std.testing.allocator;
const synthetic = @embedFile("fixtures/blocks/dictionary.network.nbt");
const synthetic_metadata = [_]i32{ 5, 7, 5, 0, 0, 9, 42, 42 };
const lookup_work = 1024 * 1024;
const PeakAllocator = struct {
    used: usize = 0,
    peak: usize = 0,

    fn get(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = allocator.rawAlloc(size, alignment, address) orelse return null;
        self.used += size;
        self.peak = @max(self.peak, self.used);
        return memory;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        self.used -= memory.len;
        allocator.rawFree(memory, alignment, address);
    }
};
const Expected = struct {
    source_count: usize,
    source_names: usize,
    network_meta_sha256: []const u8,
    metadata_lookup_sha256: []const u8,
    synthetic_queries: []const struct { name: []const u8, metadata: i32, network_id: ?u32 },
};

fn load() !std.json.Parsed(Expected) {
    return std.json.parseFromSlice(Expected, allocator, @embedFile("fixtures/blocks/dictionary.json"), .{});
}

fn expectDigest(expected: []const u8, hash: *std.crypto.hash.sha2.Sha256) !void {
    var actual: [32]u8 = undefined;
    hash.final(&actual);
    var oracle: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&oracle, expected);
    try std.testing.expectEqualSlices(u8, &oracle, &actual);
}

test "palette state mappings and metadata rules match public upstream methods" {
    const expected = try load();
    defer expected.deinit();
    var palette = try BlockPalette.init(allocator, synthetic, &synthetic_metadata, 42, .{});
    defer palette.deinit();
    try equal(synthetic_metadata.len, palette.count());
    var different_index = false;
    for (0..palette.count()) |index| {
        const network: BlockPalette.NetworkId = .{ .value = @intCast(index) };
        const id = palette.fromNetwork(network).?;
        different_index = different_index or id.index != network.value;
        try equal(network, palette.toNetwork(id).?);
        const view = palette.get(id).?;
        try equal(synthetic_metadata[index], view.metadata);
        var state = try BlockState.decode(allocator, palette.encodedRoot(id).?, .network, .{});
        state.version = -123;
        try equal(id, (try palette.find(&state, lookup_work)).?);
        try std.testing.expectEqualStrings(state.key.bytes, view.key.bytes);
        var output: [16 * 1024]u8 = undefined;
        try std.testing.expectEqualSlices(u8, view.property_key, try state.encodeProperties(&output));
    }
    try std.testing.expect(different_index);
    for (expected.value.synthetic_queries) |query| {
        const actual = try palette.findByMetadata(query.name, query.metadata, lookup_work);
        if (query.network_id) |network| {
            try equal(network, palette.toNetwork(actual.?).?.value);
        } else try equal(null, actual);
    }
}

test "complete runtime palette reproduces upstream state and metadata lookups" {
    const expected = try load();
    defer expected.deinit();
    const metadata = try std.json.parseFromSlice([]const i32, allocator, data.block_state_meta_map, .{});
    defer metadata.deinit();
    var palette = try BlockPalette.init(allocator, data.canonical_block_states, metadata.value, 7, .{});
    defer palette.deinit();
    try equal(expected.value.source_count, palette.count());
    var source_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.canonical_block_states, &source_digest, .{});
    try std.testing.expectEqualSlices(u8, &source_digest, &palette.source_sha256);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (0..palette.count()) |network| {
        const id = palette.fromNetwork(.{ .value = @intCast(network) }).?;
        const state = try BlockState.decode(allocator, palette.encodedRoot(id).?, .network, .{});
        try equal(id, (try palette.find(&state, lookup_work)).?);
        try equal(@as(u32, @intCast(network)), palette.toNetwork(id).?.value);
        const entry = palette.get(id).?;
        try equal(metadata.value[network], entry.metadata);
        var pair: [8]u8 = undefined;
        std.mem.writeInt(u32, pair[0..4], @intCast(network), .little);
        std.mem.writeInt(i32, pair[4..8], entry.metadata, .little);
        hash.update(&pair);
    }
    try expectDigest(expected.value.network_meta_sha256, &hash);
    var metadata_hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var previous: ?[]const u8 = null;
    var name_count: usize = 0;
    // Internal IDs are ordered by name and canonical property key.
    for (0..palette.count()) |index| {
        const view = palette.get(.{ .owner = 7, .index = @intCast(index) }).?;
        if (previous) |name| {
            if (std.mem.eql(u8, name, view.key.bytes)) continue;
        }
        previous = view.key.bytes;
        name_count += 1;
        for ([_]i32{ -1, 0, 1, 15, 509, 510 }) |meta| {
            const id = try palette.findByMetadata(view.key.bytes, meta, lookup_work);
            const value: u32 = if (id) |found| palette.toNetwork(found).?.value else std.math.maxInt(u32);
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, value, .little);
            metadata_hash.update(&bytes);
        }
    }
    try equal(expected.value.source_names, name_count);
    try expectDigest(expected.value.metadata_lookup_sha256, &metadata_hash);
}

test "palette IDs reject foreign lifetimes and invalid network or internal indices" {
    var first = try BlockPalette.init(allocator, synthetic, &synthetic_metadata, 1, .{});
    defer first.deinit();
    var second = try BlockPalette.init(allocator, synthetic, &synthetic_metadata, 2, .{});
    defer second.deinit();
    const id = first.fromNetwork(.{ .value = 0 }).?;
    try equal(null, second.get(id));
    try equal(null, second.toNetwork(id));
    try equal(null, second.encodedRoot(id));
    try equal(null, first.fromNetwork(.{ .value = @intCast(first.count()) }));
    try equal(null, first.fromNetwork(.{ .value = std.math.maxInt(u32) }));
    try equal(null, first.get(.{ .owner = 1, .index = std.math.maxInt(u32) }));
    var unknown = try BlockState.decode(allocator, first.encodedRoot(id).?, .network, .{});
    unknown.key = .{ .bytes = "shulvyr:missing" };
    try equal(null, try first.find(&unknown, lookup_work));
    try equal(null, try first.findByMetadata("stone", 0, lookup_work));
}

fn allocationCase(failing: std.mem.Allocator) !void {
    var palette = try BlockPalette.init(failing, synthetic, &synthetic_metadata, 1, .{});
    defer palette.deinit();
    try equal(synthetic_metadata.len, palette.count());
}

test "palette allocation and resource failures release every partial buffer" {
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
    try expectError(error.InvalidOwner, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 0, .{}));
    try expectError(error.InvalidLimits, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 1, .{ .max_states = 65537 }));
    try expectError(error.ByteLimit, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 1, .{ .max_bytes = synthetic.len - 1 }));
    try expectError(error.StateLimit, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 1, .{ .max_states = 7 }));
    try expectError(error.WorkLimit, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 1, .{ .max_work = 0 }));
    try expectError(error.AllocationLimit, BlockPalette.init(std.testing.failing_allocator, synthetic, &synthetic_metadata, 1, .{ .max_allocated_bytes = 0 }));
    try expectError(error.MetadataMismatch, BlockPalette.init(allocator, synthetic, synthetic_metadata[0..7], 1, .{}));
    var palette = try BlockPalette.init(allocator, synthetic, &synthetic_metadata, 1, .{});
    defer palette.deinit();
    // All work succeeds until the last required charge, then cleans up.
    try expectError(error.WorkLimit, BlockPalette.init(allocator, synthetic, &synthetic_metadata, 1, .{ .max_work = palette.build_work - 1 }));
    const state = try BlockState.decode(allocator, palette.encodedRoot(palette.fromNetwork(.{ .value = 0 }).?).?, .network, .{});
    try expectError(error.WorkLimit, palette.find(&state, 0));
    try expectError(error.WorkLimit, palette.findByMetadata("shulvyr:test", 5, 0));
}

test "empty palettes are valid and duplicate state identities are rejected" {
    var empty = try BlockPalette.init(std.testing.failing_allocator, "", &.{}, 1, .{ .max_work = 0, .max_allocated_bytes = 0 });
    defer empty.deinit();
    try equal(@as(usize, 0), empty.count());
    try equal(null, empty.fromNetwork(.{ .value = 0 }));
    try equal(null, try empty.findByMetadata("minecraft:air", 0, 0));
    const root = @embedFile("fixtures/blocks/case-0.network.nbt");
    var repeated: [2 * root.len]u8 = undefined;
    @memcpy(repeated[0..root.len], root);
    @memcpy(repeated[root.len..], root);
    try expectError(error.DuplicateState, BlockPalette.init(allocator, &repeated, &.{ 0, 1 }, 1, .{}));
}

test "palette stream errors never skip malformed tails or missing metadata" {
    for (0..synthetic.len) |length| {
        var partial = BlockPalette.init(allocator, synthetic[0..length], &synthetic_metadata, 1, .{}) catch |err| switch (err) {
            error.UnexpectedEnd, error.MetadataMismatch => continue,
            else => return err,
        };
        partial.deinit();
        return error.AcceptedTruncatedPalette;
    }
    var malformed: [synthetic.len + 1]u8 = undefined;
    @memcpy(malformed[0..synthetic.len], synthetic);
    malformed[synthetic.len] = 0;
    try expectError(error.UnexpectedEndTag, BlockPalette.init(allocator, &malformed, &synthetic_metadata, 1, .{}));
    try expectError(error.MetadataMismatch, BlockPalette.init(allocator, synthetic, &.{ 5, 7, 5, 0, 0, 9, 42, 42, 0 }, 1, .{}));
}

test "metadata is copied at full i32 width and sort work exhaustion is explicit" {
    var metadata = synthetic_metadata;
    metadata[3] = std.math.minInt(i32);
    metadata[7] = std.math.maxInt(i32);
    var palette = try BlockPalette.init(allocator, synthetic, &metadata, 1, .{});
    defer palette.deinit();
    @memset(&metadata, 0);
    try equal(std.math.minInt(i32), palette.get(palette.fromNetwork(.{ .value = 3 }).?).?.metadata);
    try equal(std.math.maxInt(i32), palette.get(palette.fromNetwork(.{ .value = 7 }).?).?.metadata);
    var scan_work: usize = 0;
    for (0..palette.count()) |network| {
        const id = palette.fromNetwork(.{ .value = @intCast(network) }).?;
        scan_work += 2 * (palette.encodedRoot(id).?.len + palette.get(id).?.property_key.len + 1);
    }
    try expectError(error.WorkLimit, BlockPalette.init(allocator, synthetic, &synthetic_metadata, 1, .{ .max_work = scan_work }));
}

test "palette allocation budget includes simultaneous retained and temporary storage" {
    var measured: PeakAllocator = .{};
    var first = try BlockPalette.init(measured.get(), synthetic, &synthetic_metadata, 1, .{});
    first.deinit();
    try equal(@as(usize, 0), measured.used);
    var bounded: PeakAllocator = .{};
    var second = try BlockPalette.init(bounded.get(), synthetic, &synthetic_metadata, 1, .{ .max_allocated_bytes = measured.peak });
    second.deinit();
    try equal(@as(usize, 0), bounded.used);
    try std.testing.expect(bounded.peak <= measured.peak);
    var rejected: PeakAllocator = .{};
    try expectError(error.AllocationLimit, BlockPalette.init(rejected.get(), synthetic, &synthetic_metadata, 1, .{ .max_allocated_bytes = measured.peak - 1 }));
    try equal(@as(usize, 0), rejected.used);
    try std.testing.expect(rejected.peak < measured.peak);
}
