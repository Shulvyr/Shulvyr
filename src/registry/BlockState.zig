const std = @import("std");
const nbt = @import("../foundation/nbt.zig");
const ResourceKey = @import("ResourceKey.zig");
const BlockState = @This();

pub const max_properties = 32;
pub const max_property_name_bytes = 128;
pub const max_property_string_bytes = 256;
pub const Value = union(enum) {
    byte: i8,
    int: i32,
    string: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .byte => |value| value == b.byte,
            .int => |value| value == b.int,
            .string => |value| std.mem.eql(u8, value, b.string),
        };
    }
};
pub const Property = struct { name: []const u8, value: Value };
pub const Limits = struct {
    codec: nbt.Limits = .{
        .max_bytes = 4096,
        .max_depth = 8,
        .max_nodes = 128,
        .max_collection_len = 64,
        .max_string_bytes = 256,
        .max_allocated_bytes = 16 * 1024,
        .max_work = 16 * 1024,
    },
    property_count: usize = max_properties,
};
pub const Error = nbt.Error || error{
    InvalidResourceKey,
    InvalidBlockState,
    DuplicateField,
    DuplicateProperty,
    UnknownField,
    UnsupportedPropertyType,
    PropertyLimit,
};

/// Values borrow the encoded input, never the temporary decoded node storage.
/// Keep input immutable while this state or its property views are in use.
key: ResourceKey,
version: i32,
property_storage: [max_properties]Property = undefined,
property_count: u8 = 0,

pub fn properties(self: *const BlockState) []const Property {
    return self.property_storage[0..self.property_count];
}

pub fn getProperty(self: *const BlockState, name: []const u8) ?Value {
    if (name.len > max_property_name_bytes) return null;
    for (self.properties()) |property| {
        if (std.mem.eql(u8, property.name, name)) return property.value;
    }
    return null;
}

/// Matches the reference's type-and-properties identity. Version is separate.
pub fn eql(self: *const BlockState, other: *const BlockState) bool {
    if (!std.mem.eql(u8, self.key.bytes, other.key.bytes) or self.property_count != other.property_count) return false;
    for (self.properties(), other.properties()) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or !a.value.eql(b.value)) return false;
    }
    return true;
}

/// Reference dictionary key: sorted little-endian property compound, or empty.
/// Errors leave output intact, including when output aliases a borrowed value.
pub fn encodeProperties(self: *const BlockState, output: []u8) Error![]const u8 {
    if (self.property_count == 0) return output[0..0];
    if (overlaps(output, std.mem.asBytes(self)) or overlaps(output, self.key.bytes)) return error.OverlappingOutput;
    for (self.properties()) |property| {
        if (overlaps(output, property.name)) return error.OverlappingOutput;
        switch (property.value) {
            .string => |value| if (overlaps(output, value)) return error.OverlappingOutput,
            else => {},
        }
    }
    var nodes: [max_properties + 1]nbt.Node = undefined;
    nodes[0] = .{ .value = .{ .compound = .{ .first = 1, .count = self.property_count } } };
    for (self.properties(), 0..) |property, index| {
        nodes[index + 1] = .{
            .name = property.name,
            .value = switch (property.value) {
                .byte => |value| .{ .byte = value },
                .int => |value| .{ .int = value },
                .string => |value| .{ .string = value },
            },
            .next_sibling = if (index + 1 < self.property_count) @intCast(index + 2) else null,
        };
    }
    return nbt.encode(output, nodes[0 .. 1 + self.property_count], .little_endian, .{});
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const left = @intFromPtr(a.ptr);
    const right = @intFromPtr(b.ptr);
    return if (left <= right) right - left < a.len else left - right < b.len;
}

pub fn decode(allocator: std.mem.Allocator, input: []const u8, format: nbt.Format, limits: Limits) Error!BlockState {
    try validateLimits(limits);
    var document = try nbt.decode(allocator, input, format, limits.codec);
    defer document.deinit();
    return fromValidated(document.nodes, limits);
}

pub const DecodedPrefix = struct { state: BlockState, bytes_read: usize };

pub fn decodePrefix(allocator: std.mem.Allocator, input: []const u8, format: nbt.Format, limits: Limits) Error!DecodedPrefix {
    try validateLimits(limits);
    var prefix = try nbt.decodePrefix(allocator, input, format, limits.codec);
    defer prefix.document.deinit();
    return .{ .state = try fromValidated(prefix.document.nodes, limits), .bytes_read = prefix.bytes_read };
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.property_count > max_properties) return error.InvalidLimits;
}

/// Only called with the structurally validated, immutable output of nbt.decode.
fn fromValidated(nodes: []const nbt.Node, limits: Limits) Error!BlockState {
    const fields = switch (nodes[0].value) {
        .compound => |children| children,
        else => return error.InvalidBlockState,
    };
    var key: ?ResourceKey = null;
    var states: ?nbt.Children = null;
    var version: ?i32 = null;
    var metadata_seen = false;
    var index = fields.first;
    for (0..fields.count) |_| {
        const node = nodes[index.?];
        if (std.mem.eql(u8, node.name, "name")) {
            if (key != null) return error.DuplicateField;
            key = switch (node.value) {
                .string => |name| try ResourceKey.parse(name),
                else => return error.InvalidBlockState,
            };
        } else if (std.mem.eql(u8, node.name, "states")) {
            if (states != null) return error.DuplicateField;
            states = switch (node.value) {
                .compound => |children| children,
                else => return error.InvalidBlockState,
            };
        } else if (std.mem.eql(u8, node.name, "version")) {
            if (version != null) return error.DuplicateField;
            version = switch (node.value) {
                .int => |value| value,
                else => return error.InvalidBlockState,
            };
        } else if (std.mem.eql(u8, node.name, "PMMPDataVersion")) {
            if (metadata_seen) return error.DuplicateField;
            metadata_seen = true;
        } else return error.UnknownField;
        index = node.next_sibling;
    }
    const entries = states orelse return error.InvalidBlockState;
    var result: BlockState = .{ .key = key orelse return error.InvalidBlockState, .version = version orelse 0 };
    if (entries.count > limits.property_count) return error.PropertyLimit;
    index = entries.first;
    for (0..entries.count) |_| {
        const node = nodes[index.?];
        if (node.name.len > max_property_name_bytes) return error.PropertyLimit;
        const value: Value = switch (node.value) {
            .byte => |number| .{ .byte = number },
            .int => |number| .{ .int = number },
            .string => |text| blk: {
                if (text.len > max_property_string_bytes) return error.PropertyLimit;
                break :blk .{ .string = text };
            },
            else => return error.UnsupportedPropertyType,
        };
        result.property_storage[result.property_count] = .{ .name = node.name, .value = value };
        result.property_count += 1;
        index = node.next_sibling;
    }
    // At most 32 entries with bounded names. Retain typed values when sorting.
    std.sort.insertion(Property, result.property_storage[0..result.property_count], {}, struct {
        fn less(_: void, a: Property, b: Property) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    for (result.properties(), 0..) |property, position| {
        if (position > 0 and std.mem.eql(u8, property.name, result.property_storage[position - 1].name)) return error.DuplicateProperty;
    }
    return result;
}
