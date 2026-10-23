pub const Case = struct {
    name: []const u8,
    rows: []const u8,
    order: []const u8,
    expected: ?[]const u8 = null,
};

pub const cases = [_]Case{
    .{ .name = "valid", .rows = ".{.{ .key = \"test:a\", .network_id = -7 }}", .order = ".{0}" },
    .{ .name = "missing_index", .rows = ".{.{ .key = \"test:a\", .network_id = 7 }}", .order = ".{}", .expected = "complete bounded network index" },
    .{ .name = "duplicate_key", .rows = ".{.{ .key = \"test:a\", .network_id = 7 }, .{ .key = \"test:a\", .network_id = 8 }}", .order = ".{0, 1}", .expected = "keys must be unique and sorted" },
    .{ .name = "duplicate_network_id", .rows = ".{.{ .key = \"test:a\", .network_id = 7 }, .{ .key = \"test:b\", .network_id = 7 }}", .order = ".{0, 1}", .expected = "network IDs must be unique and sorted" },
    .{ .name = "duplicate_index", .rows = ".{.{ .key = \"test:a\", .network_id = 7 }, .{ .key = \"test:b\", .network_id = 8 }}", .order = ".{0, 0}", .expected = "missing or duplicate mappings" },
    .{ .name = "index_out_of_range", .rows = ".{.{ .key = \"test:a\", .network_id = 7 }}", .order = ".{1}", .expected = "missing or duplicate mappings" },
    .{ .name = "network_out_of_range", .rows = ".{.{ .key = \"test:a\", .network_id = 32768 }}", .order = ".{0}", .expected = "network ID out of range" },
    .{ .name = "invalid_key", .rows = ".{.{ .key = \"stone\", .network_id = 7 }}", .order = ".{0}", .expected = "Invalid registry resource key" },
};
