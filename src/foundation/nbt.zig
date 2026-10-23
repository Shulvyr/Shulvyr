const std = @import("std");
const binary = @import("binary.zig");

pub const Format = enum { big_endian, little_endian, network };
pub const Type = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
};

pub const Error = binary.ReadError || binary.WriteError || std.mem.Allocator.Error || error{
    InvalidLimits,
    ByteLimit,
    DepthLimit,
    NodeLimit,
    CollectionLimit,
    AllocationLimit,
    WorkLimit,
    NegativeLength,
    UnknownTag,
    UnsupportedTag,
    UnexpectedEndTag,
    NonEmptyEndList,
    TrailingData,
    InvalidTree,
    OverlappingOutput,
};

/// Bounds apply to each tree traversal. Decode and encode each perform two.
/// Encode also checks slice overlap in one linear pass over validated nodes.
/// Root depth is one. The hard recursion ceiling is 64, including scalar nodes.
pub const Limits = struct {
    max_bytes: usize = 2 * 1024 * 1024,
    max_depth: usize = 64,
    max_nodes: usize = 65536,
    max_collection_len: usize = 65536,
    max_string_bytes: usize = 32767,
    max_allocated_bytes: usize = 16 * 1024 * 1024,
    max_work: usize = 4 * 1024 * 1024,

    fn validate(self: Limits) Error!void {
        if (self.max_depth == 0 or self.max_depth > 64 or
            self.max_nodes > std.math.maxInt(u32) or self.max_string_bytes > 32767)
            return error.InvalidLimits;
    }
};

/// Child indices refer to the same immutable node slice, in depth-first order.
/// Follow next_sibling exactly count times. An empty collection has no first.
pub const Children = struct { first: ?u32 = null, count: u32 = 0 };
pub const List = struct { element_type: Type, children: Children = .{} };
pub const Value = union(Type) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const u8,
    string: []const u8,
    list: List,
    compound: Children,
    int_array: []const i32,
};
pub const Node = struct {
    name: []const u8 = "",
    value: Value,
    next_sibling: ?u32 = null,
};

/// Owns two allocations at most. Names, strings and byte arrays borrow input.
/// Keep the input immutable and alive until deinit. Do not copy owning Documents.
pub const Document = struct {
    nodes: []const Node,
    allocator: std.mem.Allocator,
    integers: []i32,

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.integers);
        self.allocator.free(self.nodes);
        self.* = undefined;
    }
};

const Budget = struct {
    limits: Limits,
    nodes: usize = 0,
    allocation: usize = 0,
    work: usize = 0,

    fn spend(self: *Budget, amount: usize) Error!void {
        if (amount > self.limits.max_work - self.work) return error.WorkLimit;
        self.work += amount;
    }

    fn allocate(self: *Budget, count: usize, size: usize) Error!void {
        if (count > (self.limits.max_allocated_bytes - self.allocation) / size)
            return error.AllocationLimit;
        self.allocation += count * size;
    }

    fn node(self: *Budget, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.DepthLimit;
        if (self.nodes == self.limits.max_nodes) return error.NodeLimit;
        try self.spend(1);
        try self.allocate(1, @sizeOf(Node));
        self.nodes += 1;
    }

    fn collection(self: *Budget, count: usize) Error!void {
        if (count > self.limits.max_collection_len) return error.CollectionLimit;
    }
};

fn endian(format: Format) std.builtin.Endian {
    return if (format == .big_endian) .big else .little;
}

fn tagType(raw: u8) Error!Type {
    if (raw == 12) return error.UnsupportedTag;
    return std.enums.fromInt(Type, raw) orelse error.UnknownTag;
}

const Parser = struct {
    reader: binary.Reader,
    format: Format,
    budget: Budget,
    nodes: ?[]Node = null,
    integers: ?[]i32 = null,
    integer_count: usize = 0,

    fn number(self: *Parser, comptime T: type) Error!T {
        if (self.format == .network and (T == i32 or T == i64))
            return self.reader.varInt(T);
        return self.reader.integer(T, endian(self.format));
    }

    fn length(self: *Parser) Error!usize {
        const signed = try self.number(i32);
        if (signed < 0) return error.NegativeLength;
        const count: usize = @intCast(signed);
        try self.budget.collection(count);
        return count;
    }

    fn text(self: *Parser) Error![]const u8 {
        const count: usize = if (self.format == .network)
            try self.reader.varUInt(u32)
        else
            try self.reader.integer(u16, endian(self.format));
        if (count > self.budget.limits.max_string_bytes) return error.StringTooLong;
        try self.budget.spend(count);
        return self.reader.bytes(count);
    }

    fn root(self: *Parser, require_end: bool) Error!void {
        const kind = try tagType(try self.reader.integer(u8, .little));
        if (kind == .end) return error.UnexpectedEndTag;
        const name = try self.text();
        _ = try self.node(kind, name, 1);
        if (require_end and self.reader.remaining() != 0) return error.TrailingData;
    }

    fn link(self: *Parser, children: *Children, previous: *?u32, child: u32) void {
        if (previous.*) |index| {
            if (self.nodes) |nodes| nodes[index].next_sibling = child;
        } else children.first = child;
        previous.* = child;
        children.count += 1;
    }

    fn node(self: *Parser, kind: Type, name: []const u8, depth: usize) Error!u32 {
        const index: u32 = @intCast(self.budget.nodes);
        try self.budget.node(depth);
        const value: Value = switch (kind) {
            .end => return error.UnexpectedEndTag,
            .byte => .{ .byte = try self.number(i8) },
            .short => .{ .short = try self.number(i16) },
            .int => .{ .int = try self.number(i32) },
            .long => .{ .long = try self.number(i64) },
            .float => .{ .float = @bitCast(try self.reader.integer(u32, endian(self.format))) },
            .double => .{ .double = @bitCast(try self.reader.integer(u64, endian(self.format))) },
            .byte_array => blk: {
                const count = try self.length();
                try self.budget.spend(count);
                break :blk .{ .byte_array = try self.reader.bytes(count) };
            },
            .string => .{ .string = try self.text() },
            .int_array => blk: {
                const count = try self.length();
                const minimum_width: usize = if (self.format == .network) 1 else 4;
                if (count > self.reader.remaining() / minimum_width) return error.UnexpectedEnd;
                try self.budget.spend(count);
                try self.budget.allocate(count, @sizeOf(i32));
                const start = self.integer_count;
                self.integer_count += count;
                for (0..count) |i| {
                    const value = try self.number(i32);
                    if (self.integers) |integers| integers[start + i] = value;
                }
                break :blk .{ .int_array = if (self.integers) |integers| integers[start..][0..count] else &.{} };
            },
            .list => blk: {
                const element = try tagType(try self.reader.integer(u8, .little));
                const count = try self.length();
                if (element == .end and count != 0) return error.NonEmptyEndList;
                // Check the declared size before attempting any child traversal.
                if (count > self.budget.limits.max_nodes - self.budget.nodes) return error.NodeLimit;
                var children: Children = .{};
                var previous: ?u32 = null;
                for (0..count) |_| {
                    const child = try self.node(element, "", depth + 1);
                    self.link(&children, &previous, child);
                }
                break :blk .{ .list = .{ .element_type = element, .children = children } };
            },
            .compound => blk: {
                var children: Children = .{};
                var previous: ?u32 = null;
                while (true) {
                    const child_type = try tagType(try self.reader.integer(u8, .little));
                    if (child_type == .end) break;
                    try self.budget.collection(@as(usize, children.count) + 1);
                    const child_name = try self.text();
                    const child = try self.node(child_type, child_name, depth + 1);
                    self.link(&children, &previous, child);
                }
                break :blk .{ .compound = children };
            },
        };
        if (self.nodes) |nodes| nodes[index] = .{ .name = name, .value = value };
        return index;
    }
};

/// Decodes exactly one complete named root. Framing and decompression are external.
/// Structural validation and budget checks finish before either allocation.
pub fn decode(allocator: std.mem.Allocator, input: []const u8, format: Format, limits: Limits) Error!Document {
    try limits.validate();
    if (input.len > limits.max_bytes) return error.ByteLimit;
    var scan: Parser = .{ .reader = .{ .input = input }, .format = format, .budget = .{ .limits = limits } };
    try scan.root(true);
    return materialize(allocator, input, format, limits, &scan);
}

pub const DecodedPrefix = struct { document: Document, bytes_read: usize };

/// Decodes the first named root and returns its exact byte length.
/// Limits apply to that root. The caller must bound a sequence's total work,
/// bytes, root count and retained documents, and validate the remaining input.
pub fn decodePrefix(allocator: std.mem.Allocator, input: []const u8, format: Format, limits: Limits) Error!DecodedPrefix {
    try limits.validate();
    const bounded = input[0..@min(input.len, limits.max_bytes)];
    var scan: Parser = .{ .reader = .{ .input = bounded }, .format = format, .budget = .{ .limits = limits } };
    scan.root(false) catch |err| {
        if (err == error.UnexpectedEnd and bounded.len < input.len) return error.ByteLimit;
        return err;
    };
    const consumed = scan.reader.position;
    return .{
        .document = try materialize(allocator, input[0..consumed], format, limits, &scan),
        .bytes_read = consumed,
    };
}

fn materialize(allocator: std.mem.Allocator, input: []const u8, format: Format, limits: Limits, scan: *const Parser) Error!Document {
    const nodes = try allocator.alloc(Node, scan.budget.nodes);
    errdefer allocator.free(nodes);
    const integers = try allocator.alloc(i32, scan.integer_count);
    errdefer allocator.free(integers);
    var parse: Parser = .{
        .reader = .{ .input = input },
        .format = format,
        .budget = .{ .limits = limits },
        .nodes = nodes,
        .integers = integers,
    };
    try parse.root(true);
    return .{ .nodes = nodes, .allocator = allocator, .integers = integers };
}

const Emitter = struct {
    nodes: []const Node,
    format: Format,
    budget: Budget,
    output: ?[]u8 = null,
    position: usize = 0,

    fn bytes(self: *Emitter, data: []const u8) Error!void {
        if (data.len > self.budget.limits.max_bytes - self.position) return error.ByteLimit;
        if (self.output) |output| @memcpy(output[self.position..][0..data.len], data);
        self.position += data.len;
    }

    fn number(self: *Emitter, comptime T: type, value: T) Error!void {
        var buffer: [10]u8 = undefined;
        var writer: binary.Writer = .{ .output = &buffer };
        if (self.format == .network and (T == i32 or T == i64)) {
            try writer.varInt(T, value);
        } else try writer.integer(T, value, endian(self.format));
        try self.bytes(writer.written());
    }

    fn text(self: *Emitter, value: []const u8) Error!void {
        if (value.len > self.budget.limits.max_string_bytes) return error.StringTooLong;
        try self.budget.spend(value.len);
        if (self.format == .network) {
            var buffer: [5]u8 = undefined;
            var writer: binary.Writer = .{ .output = &buffer };
            try writer.varUInt(u32, @intCast(value.len));
            try self.bytes(writer.written());
        } else try self.number(u16, @intCast(value.len));
        try self.bytes(value);
    }

    fn length(self: *Emitter, count: usize) Error!void {
        try self.budget.collection(count);
        if (count > std.math.maxInt(i32)) return error.CollectionLimit;
        try self.number(i32, @intCast(count));
    }

    fn children(self: *Emitter, group: Children, element: ?Type, depth: usize) Error!void {
        try self.budget.collection(group.count);
        var next = group.first;
        for (0..group.count) |_| {
            const index = next orelse return error.InvalidTree;
            if (index >= self.nodes.len) return error.InvalidTree;
            const child = self.nodes[index];
            if (element) |kind| {
                if (child.name.len != 0 or std.meta.activeTag(child.value) != kind) return error.InvalidTree;
            }
            try self.node(index, element == null, depth + 1);
            next = child.next_sibling;
        }
        if (next != null) return error.InvalidTree;
    }

    fn node(self: *Emitter, index: u32, named: bool, depth: usize) Error!void {
        // Requiring preorder catches cycles, aliases, missing and repeated nodes.
        if (index != self.budget.nodes or index >= self.nodes.len) return error.InvalidTree;
        try self.budget.node(depth);
        const current = self.nodes[index];
        const kind = std.meta.activeTag(current.value);
        if (kind == .end) return error.UnexpectedEndTag;
        if (named) {
            try self.number(u8, @backingInt(kind));
            try self.text(current.name);
        }
        switch (current.value) {
            .end => unreachable,
            .byte => |value| try self.number(i8, value),
            .short => |value| try self.number(i16, value),
            .int => |value| try self.number(i32, value),
            .long => |value| try self.number(i64, value),
            .float => |value| try self.number(u32, @bitCast(value)),
            .double => |value| try self.number(u64, @bitCast(value)),
            .string => |value| try self.text(value),
            .byte_array => |value| {
                try self.length(value.len);
                try self.budget.spend(value.len);
                try self.bytes(value);
            },
            .int_array => |value| {
                try self.length(value.len);
                try self.budget.spend(value.len);
                try self.budget.allocate(value.len, @sizeOf(i32));
                for (value) |item| try self.number(i32, item);
            },
            .list => |list| {
                if (list.element_type == .end and list.children.count != 0) return error.NonEmptyEndList;
                try self.number(u8, @backingInt(list.element_type));
                try self.length(list.children.count);
                try self.children(list.children, list.element_type, depth);
            },
            .compound => |group| {
                try self.children(group, null, depth);
                try self.number(u8, 0);
            },
        }
    }

    fn root(self: *Emitter) Error!void {
        if (self.nodes.len == 0 or self.nodes[0].next_sibling != null) return error.InvalidTree;
        try self.node(0, true, 1);
        if (self.budget.nodes != self.nodes.len) return error.InvalidTree;
    }
};

pub fn encodedSize(nodes: []const Node, format: Format, limits: Limits) Error!usize {
    try limits.validate();
    var measure: Emitter = .{ .nodes = nodes, .format = format, .budget = .{ .limits = limits } };
    try measure.root();
    return measure.position;
}

fn overlaps(comptime T: type, a: []const T, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_bytes = std.mem.sliceAsBytes(a).len;
    return if (a_start <= b_start) b_start - a_start < a_bytes else a_start - b_start < b.len;
}

/// Validates the whole immutable tree before writing. Errors preserve output.
/// Output must not overlap nodes or any referenced slice, including borrowed input.
pub fn encode(output: []u8, nodes: []const Node, format: Format, limits: Limits) Error![]const u8 {
    const size = try encodedSize(nodes, format, limits);
    if (size > output.len) return error.NoSpace;
    const destination = output[0..size];
    if (overlaps(Node, nodes, destination)) return error.OverlappingOutput;
    for (nodes) |node| {
        if (overlaps(u8, node.name, destination)) return error.OverlappingOutput;
        switch (node.value) {
            .string, .byte_array => |data| if (overlaps(u8, data, destination)) return error.OverlappingOutput,
            .int_array => |data| if (overlaps(i32, data, destination)) return error.OverlappingOutput,
            else => {},
        }
    }
    var emitter: Emitter = .{ .nodes = nodes, .format = format, .budget = .{ .limits = limits }, .output = destination };
    try emitter.root();
    return destination;
}

test {
    _ = @import("nbt_test.zig");
}
