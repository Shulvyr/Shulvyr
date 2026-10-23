const std = @import("std");
const ResourceKey = @import("ResourceKey.zig");

pub const Domain = enum { item, biome };
pub const Row = struct { key: []const u8, network_id: i32 };

/// Immutable compile-time catalog. Each domain and snapshot has distinct ID types.
/// Input arrays and keys become static storage. Lookups allocate nothing.
pub fn Registry(comptime domain: Domain, comptime Raw: type, comptime rows: []const Row, comptime network_order: []const u32) type {
    comptime {
        @setEvalBranchQuota(2_000_000);
        if (rows.len == 0 or rows.len > 65_536 or network_order.len != rows.len) {
            @compileError("Registry requires a complete bounded network index");
        }
        var seen: [rows.len]bool = @splat(false);
        for (rows, 0..) |row, index| {
            _ = ResourceKey.parse(row.key) catch @compileError("Invalid registry resource key");
            _ = std.math.cast(Raw, row.network_id) orelse @compileError("Registry network ID out of range");
            if (index > 0 and std.mem.order(u8, rows[index - 1].key, row.key) != .lt) {
                @compileError("Registry keys must be unique and sorted");
            }
        }
        for (network_order, 0..) |index, position| {
            if (index >= rows.len or seen[index]) @compileError("Registry network index has missing or duplicate mappings");
            seen[index] = true;
            if (position > 0 and rows[network_order[position - 1]].network_id >= rows[index].network_id) {
                @compileError("Registry network IDs must be unique and sorted");
            }
        }
    }
    return struct {
        pub const scope = domain;
        pub const count = rows.len;

        /// Snapshot-local index. Never persist or transmit its backing integer.
        pub const Id = enum(u32) {
            _,
            pub const catalog_domain = domain;
            pub const catalog_rows = rows;
        };
        /// Source dictionary value. A protocol adapter must select the right snapshot.
        pub const NetworkId = struct {
            value: Raw,
            pub const catalog_domain = domain;
            pub const catalog_rows = rows;
        };
        pub const Entry = struct { key: ResourceKey, network_id: NetworkId };

        pub fn get(id: Id) ?Entry {
            const index = @backingInt(id);
            if (index >= rows.len) return null;
            const row = rows[index];
            return .{ .key = .{ .bytes = row.key }, .network_id = .{ .value = @intCast(row.network_id) } };
        }

        /// Requires an explicit namespace. Unknown and malformed keys return null.
        pub fn resolve(text: []const u8) ?Id {
            _ = ResourceKey.parse(text) catch return null;
            var lower: usize = 0;
            var upper: usize = rows.len;
            while (lower < upper) {
                const middle = lower + (upper - lower) / 2;
                switch (std.mem.order(u8, rows[middle].key, text)) {
                    .lt => lower = middle + 1,
                    .gt => upper = middle,
                    .eq => return @fromBackingInt(@intCast(middle)),
                }
            }
            return null;
        }

        /// Unknown values return null. There is no fallback to air or a default biome.
        pub fn fromNetwork(id: NetworkId) ?Id {
            var lower: usize = 0;
            var upper: usize = network_order.len;
            while (lower < upper) {
                const middle = lower + (upper - lower) / 2;
                const index = network_order[middle];
                const value = rows[index].network_id;
                if (value < id.value) {
                    lower = middle + 1;
                } else if (value > id.value) {
                    upper = middle;
                } else {
                    return @fromBackingInt(@intCast(index));
                }
            }
            return null;
        }
    };
}

test "same integer width cannot erase domain or snapshot identity" {
    const first = &[_]Row{.{ .key = "test:a", .network_id = 3 }};
    const second = &[_]Row{.{ .key = "test:a", .network_id = 4 }};
    const order = &[_]u32{0};
    const A = Registry(.item, i16, first, order);
    const B = Registry(.biome, i16, first, order);
    const C = Registry(.item, i16, second, order);
    try std.testing.expect(A.Id != B.Id);
    try std.testing.expect(A.NetworkId != B.NetworkId);
    try std.testing.expect(A.Id != C.Id);
    try std.testing.expect(A.NetworkId != C.NetworkId);
}
