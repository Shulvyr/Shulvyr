const std = @import("std");
const ResourceKey = @This();

/// Borrows a canonical namespaced key. The bytes must outlive the key.
bytes: []const u8,

pub const max_bytes = 256;

pub fn parse(bytes: []const u8) error{InvalidResourceKey}!ResourceKey {
    if (bytes.len == 0 or bytes.len > max_bytes) return error.InvalidResourceKey;
    const colon = std.mem.indexOfScalar(u8, bytes, ':') orelse return error.InvalidResourceKey;
    if (colon == 0 or colon + 1 == bytes.len) return error.InvalidResourceKey;
    for (bytes[0..colon]) |byte| {
        if (!common(byte)) return error.InvalidResourceKey;
    }
    for (bytes[colon + 1 ..]) |byte| {
        if (!common(byte) and byte != '/') return error.InvalidResourceKey;
    }
    return .{ .bytes = bytes };
}

fn common(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or
        byte == '_' or byte == '-' or byte == '.';
}

test "resource keys are explicit, bounded and case sensitive" {
    for ([_][]const u8{ "minecraft:stone", "shulvyr:tool/hammer", "a.b-0_:c.d-1_" }) |text| {
        try std.testing.expectEqualStrings(text, (try parse(text)).bytes);
    }
    for ([_][]const u8{ "", "stone", ":stone", "minecraft:", "Minecraft:stone", "minecraft:STONE", "a:b:c", "a/b:c", "a:b c", "a:b\x00", "a:b\\c", "a:b\xc3\xa9" }) |text| {
        try std.testing.expectError(error.InvalidResourceKey, parse(text));
    }
    var boundary: [max_bytes + 1]u8 = @splat('x');
    boundary[1] = ':';
    _ = try parse(boundary[0..max_bytes]);
    try std.testing.expectError(error.InvalidResourceKey, parse(&boundary));
}
