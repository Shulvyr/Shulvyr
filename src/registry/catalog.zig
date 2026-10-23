const std = @import("std");
const Registry = @import("Registry.zig").Registry;
const generated = @import("generated.zig");

pub const Items = Registry(.item, i16, &generated.items, &generated.item_network_order);
pub const Biomes = Registry(.biome, u32, &generated.biomes, &generated.biome_network_order);
pub const source = generated.source;

test "catalog domains cannot exchange internal or network IDs" {
    try std.testing.expect(Items.Id != Items.NetworkId);
    try std.testing.expect(Items.Id != Biomes.Id);
    try std.testing.expect(Items.NetworkId != Biomes.NetworkId);
    const stone = Items.resolve("minecraft:stone").?;
    try std.testing.expect(@backingInt(stone) != @as(u32, @intCast(Items.get(stone).?.network_id.value)));
}

test "source dictionary vectors preserve signed IDs and explicit biome names" {
    for ([_]struct { key: []const u8, network: i16 }{
        .{ .key = "minecraft:air", .network = -158 },
        .{ .key = "minecraft:stone", .network = 1 },
        .{ .key = "minecraft:diamond_sword", .network = 318 },
        .{ .key = "minecraft:shield", .network = 358 },
        .{ .key = "minecraft:acacia_button", .network = -140 },
    }) |vector| {
        const id = Items.resolve(vector.key).?;
        const entry = Items.get(id).?;
        try std.testing.expectEqual(vector.network, entry.network_id.value);
        try std.testing.expectEqual(id, Items.fromNetwork(.{ .value = vector.network }).?);
        try std.testing.expectEqualStrings(vector.key, entry.key.bytes);
    }
    const plains = Biomes.resolve("minecraft:plains").?;
    try std.testing.expectEqual(@as(u32, 1), Biomes.get(plains).?.network_id.value);
    try std.testing.expectEqualStrings("minecraft:ocean", Biomes.get(Biomes.fromNetwork(.{ .value = 0 }).?).?.key.bytes);
    try std.testing.expectEqual(null, Biomes.resolve("plains"));
}

test "catalog lookup rejects missing names, network gaps and invalid internal IDs" {
    for ([_][]const u8{ "minecraft:missing", "minecraft:Stone", "stone", "", "minecraft:stone/x" }) |key| {
        try std.testing.expectEqual(null, Items.resolve(key));
    }
    try std.testing.expectEqual(null, Items.fromNetwork(.{ .value = std.math.minInt(i16) }));
    try std.testing.expectEqual(null, Items.fromNetwork(.{ .value = std.math.maxInt(i16) }));
    try std.testing.expectEqual(null, Biomes.fromNetwork(.{ .value = 255 }));
    try std.testing.expectEqual(null, Items.get(@fromBackingInt(@intCast(Items.count))));
    try std.testing.expectEqual(null, Items.get(@fromBackingInt(@intCast(std.math.maxInt(u32)))));
    try std.testing.expectEqual(null, Biomes.get(@fromBackingInt(@intCast(Biomes.count))));
}

test "every committed item and biome has both lookup directions" {
    inline for (.{ Items, Biomes }) |Catalog| {
        for (0..Catalog.count) |index| {
            const id: Catalog.Id = @fromBackingInt(@intCast(index));
            const entry = Catalog.get(id).?;
            try std.testing.expectEqual(id, Catalog.resolve(entry.key.bytes).?);
            try std.testing.expectEqual(id, Catalog.fromNetwork(entry.network_id).?);
        }
    }
    try std.testing.expectEqual(@as(usize, 2076), Items.count);
    try std.testing.expectEqual(@as(usize, 89), Biomes.count);
}
