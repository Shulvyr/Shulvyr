const std = @import("std");

pub const Config = struct {
    ticks: u64 = 20,
    tick_rate: u16 = 20,
    max_catch_up: u16 = 4,

    pub fn validate(self: Config) error{InvalidValue}!void {
        if (self.ticks == 0 or self.ticks > 1_000_000) return error.InvalidValue;
        if (self.tick_rate == 0 or self.tick_rate > 1000) return error.InvalidValue;
        if (self.max_catch_up == 0 or self.max_catch_up > 100) return error.InvalidValue;
    }
};

pub const Identity = struct {
    action: enum { init, show, inspect, rotate, recover, backup },
    directory: []const u8 = ".shulvyr",
    destination: ?[]const u8 = null,
    expected: ?[32]u8 = null,
};
pub const Command = union(enum) { help, version, run: Config, identity: Identity };
pub const ParseError = error{ UnknownArgument, MissingValue, InvalidValue, DuplicateArgument, ConflictingArguments, TooManyArguments };

pub const usage =
    \\Usage: shulvyr [options]
    \\
    \\Run a finite foundation tick loop. Defaults to 20 ticks at 20 Hz.
    \\  --ticks N          Stop after N logical ticks (1..1000000)
    \\  --tick-rate N      Wall-clock tick rate (1..1000)
    \\  --max-catch-up N   Maximum ticks per clock poll (1..100)
    \\  --version         Print the engine version
    \\  --help            Print this help
    \\
    \\Operator identity commands:
    \\  identity init|show|inspect [--directory PATH]
    \\  identity rotate|recover --expected FINGERPRINT [--directory PATH]
    \\  identity backup --destination PATH [--directory PATH]
    \\The default identity directory is .shulvyr. Fingerprints are SHA-256 hex.
    \\
;

/// Run configuration owns its numeric values. Identity paths borrow argument
/// storage through command execution.
pub fn parse(arguments: []const []const u8) ParseError!Command {
    if (arguments.len > 16) return error.TooManyArguments;
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "--help")) return .help;
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "--version")) return .version;
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], "identity")) return parseIdentity(arguments[1..]);
    var config: Config = .{};
    var seen: u3 = 0;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const name = arguments[index];
        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "--version")) return error.ConflictingArguments;
        const bit: u3 = if (std.mem.eql(u8, name, "--ticks")) 1 else if (std.mem.eql(u8, name, "--tick-rate")) 2 else if (std.mem.eql(u8, name, "--max-catch-up")) 4 else return error.UnknownArgument;
        if (seen & bit != 0) return error.DuplicateArgument;
        if (index + 1 == arguments.len) return error.MissingValue;
        const value = arguments[index + 1];
        if (value.len == 0 or value.len > 20) return error.InvalidValue;
        for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
        const number = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
        switch (bit) {
            1 => config.ticks = number,
            2 => config.tick_rate = std.math.cast(u16, number) orelse return error.InvalidValue,
            4 => config.max_catch_up = std.math.cast(u16, number) orelse return error.InvalidValue,
            else => unreachable,
        }
        seen |= bit;
    }
    try config.validate();
    return .{ .run = config };
}

fn parseIdentity(arguments: []const []const u8) ParseError!Command {
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "--help")) return .help;
    if (arguments.len == 0) return error.MissingValue;
    var command: Identity = .{ .action = std.meta.stringToEnum(@FieldType(Identity, "action"), arguments[0]) orelse return error.UnknownArgument };
    var seen: u3 = 0;
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        const name = arguments[index];
        const bit: u3 = if (std.mem.eql(u8, name, "--directory")) 1 else if (std.mem.eql(u8, name, "--destination")) 2 else if (std.mem.eql(u8, name, "--expected")) 4 else return error.UnknownArgument;
        if (seen & bit != 0) return error.DuplicateArgument;
        if (index + 1 == arguments.len) return error.MissingValue;
        const value = arguments[index + 1];
        if (value.len == 0 or value.len > std.fs.max_path_bytes or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidValue;
        switch (bit) {
            1 => command.directory = value,
            2 => command.destination = value,
            4 => {
                if (value.len != 64) return error.InvalidValue;
                var fingerprint: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&fingerprint, value) catch return error.InvalidValue;
                command.expected = fingerprint;
            },
            else => unreachable,
        }
        seen |= bit;
    }
    if ((command.action == .rotate or command.action == .recover) != (command.expected != null)) return error.ConflictingArguments;
    if ((command.action == .backup) != (command.destination != null)) return error.ConflictingArguments;
    return .{ .identity = command };
}

test "identity commands require explicit mutation pins and complete options" {
    try std.testing.expect((try parse(&.{ "identity", "--help" })) == .help);
    try std.testing.expectEqual(Identity{ .action = .init }, (try parse(&.{ "identity", "init" })).identity);
    try std.testing.expectError(error.ConflictingArguments, parse(&.{ "identity", "rotate" }));
    try std.testing.expectError(error.ConflictingArguments, parse(&.{ "identity", "backup" }));
    try std.testing.expectError(error.InvalidValue, parse(&.{ "identity", "rotate", "--expected", "not-a-fingerprint" }));
    try std.testing.expectError(error.DuplicateArgument, parse(&.{ "identity", "show", "--directory", "one", "--directory", "two" }));
    const rotated = (try parse(&.{ "identity", "rotate", "--expected", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" })).identity;
    try std.testing.expect(rotated.expected != null);
}

test "defaults and explicit configuration" {
    const defaults = (try parse(&.{})).run;
    try std.testing.expectEqual(@as(u64, 20), defaults.ticks);
    try std.testing.expectEqual(@as(u16, 20), defaults.tick_rate);
    const custom = (try parse(&.{ "--ticks", "2", "--tick-rate", "1000", "--max-catch-up", "1" })).run;
    try std.testing.expectEqual(@as(u64, 2), custom.ticks);
    try std.testing.expectEqual(@as(u16, 1000), custom.tick_rate);
    try std.testing.expectEqual(@as(u16, 1), custom.max_catch_up);
    try std.testing.expect((try parse(&.{"--help"})) == .help);
    try std.testing.expect((try parse(&.{"--version"})) == .version);
}

test "invalid and ambiguous arguments are rejected" {
    try std.testing.expectError(error.UnknownArgument, parse(&.{"--unknown"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--ticks"}));
    try std.testing.expectError(error.DuplicateArgument, parse(&.{ "--ticks", "1", "--ticks", "2" }));
    try std.testing.expectError(error.ConflictingArguments, parse(&.{ "--help", "--ticks", "1" }));
    for ([_][]const u8{ "0", "-1", "+1", " 1", "1_0", "18446744073709551616", "1000001", "" }) |value| {
        try std.testing.expectError(error.InvalidValue, parse(&.{ "--ticks", value }));
    }
    try std.testing.expectError(error.InvalidValue, parse(&.{ "--tick-rate", "1001" }));
    try std.testing.expectError(error.InvalidValue, parse(&.{ "--max-catch-up", "101" }));
    const too_many: [17][]const u8 = @splat("--ticks");
    try std.testing.expectError(error.TooManyArguments, parse(&too_many));
}
