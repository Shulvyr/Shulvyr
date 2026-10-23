const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Workspace = @import("Workspace.zig");
const Runner = @This();

gpa: Allocator,
io: Io,
logs: Io.Dir,
cwd: []const u8,
output: *Io.Writer,

pub const Options = struct {
    log: ?[]const u8 = null,
    private: bool = false,
    seconds: u32 = 600,
    stream_limit: usize = 16 * 1024 * 1024,
};

/// Returns owned stdout followed by stderr. Commands use argument arrays, never
/// a shell. Raw output stays in the owned log directory. On failure, only a
/// complete allowlisted diagnostic is public. A deadline covers pipe reads and
/// process exit, including children that close both pipes before blocking.
/// The direct child is killed and reaped on timeout. This is not a sandbox or
/// a process-tree termination guarantee. Keep external builds in owned work/.
pub fn run(self: *Runner, argv: []const []const u8, options: Options) ![]u8 {
    if (argv.len == 0 or options.seconds == 0 or options.stream_limit == 0) return error.InvalidCommand;
    if (options.log) |name| {
        try logName(name);
        if (self.logs.statFile(self.io, name, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind != .file) return error.UnsafeNativePath;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // A new attempt cannot leave a previous successful command's log.
        try self.logs.writeFile(self.io, .{ .sub_path = name, .data = "", .flags = .{ .permissions = Workspace.permissions(false) } });
    }
    var operation: Operation = .{ .runner = self, .argv = argv, .limit = options.stream_limit };
    defer if (operation.result) |result| {
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    };
    const Event = union(enum) { done: void, deadline: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(self.io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.done, Operation.execute, .{&operation});
    try select.concurrent(.deadline, Io.sleep, .{ self.io, Io.Duration.fromSeconds(options.seconds), .awake });
    const event = try select.await();
    select.cancelDiscard();
    if (event == .deadline) {
        try self.output.writeAll("Native command exceeded its deadline\n");
        return error.CommandTimeout;
    }
    if (operation.failure) |err| return err;
    const result = operation.result orelse return error.MissingCommandResult;
    const combined = try std.mem.concat(self.gpa, u8, &.{ result.stdout, result.stderr });
    errdefer self.gpa.free(combined);
    if (options.log) |name| {
        try self.logs.writeFile(self.io, .{ .sub_path = name, .data = combined, .flags = .{ .permissions = Workspace.permissions(false) } });
    }
    if (!result.term.success()) {
        if (options.private) {
            var lines = std.mem.splitScalar(u8, combined, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (safeDiagnostic(line)) try self.output.print("{s}\n", .{line});
            }
        }
        try self.output.print("Native command failed ({f})", .{result.term});
        if (options.log) |name| try self.output.print(", inspect owned log {s}", .{name});
        try self.output.writeByte('\n');
        return error.CommandFailed;
    }
    return combined;
}

pub fn step(self: *Runner, argv: []const []const u8, options: Options) !void {
    self.gpa.free(try self.run(argv, options));
}

const Operation = struct {
    runner: *Runner,
    argv: []const []const u8,
    limit: usize,
    result: ?std.process.RunResult = null,
    failure: ?anyerror = null,

    fn execute(self: *Operation) void {
        self.result = self.collect() catch |err| {
            self.failure = err;
            return;
        };
    }

    fn collect(self: *Operation) !std.process.RunResult {
        const io = self.runner.io;
        const gpa = self.runner.gpa;
        var child = try std.process.spawn(io, .{
            .argv = self.argv,
            .cwd = .{ .path = self.runner.cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        var storage: Io.File.MultiReader.Buffer(2) = undefined;
        var streams: Io.File.MultiReader = undefined;
        streams.init(gpa, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
        // Stop the producer before canceling pipe reads. A producer blocked on
        // a full pipe cannot otherwise let the pinned Windows reader quiesce.
        defer {
            child.kill(io);
            streams.deinit();
        }
        while (streams.fill(64, .none)) |_| {
            if (streams.reader(0).buffered().len > self.limit or streams.reader(1).buffered().len > self.limit) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try streams.checkAnyError();
        const term = try child.wait(io);
        const stdout = try streams.toOwnedSlice(0);
        errdefer gpa.free(stdout);
        const stderr = try streams.toOwnedSlice(1);
        return .{ .term = term, .stdout = stdout, .stderr = stderr };
    }
};

fn logName(name: []const u8) !void {
    if (name.len == 0 or name.len > 80) return error.InvalidLogName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return error.InvalidLogName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidLogName;
}

pub fn safeDiagnostic(line: []const u8) bool {
    const failed = " failed: ";
    if (std.mem.indexOf(u8, line, failed)) |position| {
        const prefix = line[0..position];
        const reason = line[position + failed.len ..];
        if (reason.len == 0) return false;
        for (reason) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
        if (std.mem.eql(u8, prefix, "callback probe") or std.mem.eql(u8, prefix, "native probe")) return true;
        if (std.mem.startsWith(u8, prefix, "transport cycle ")) return digits(prefix["transport cycle ".len..]);
        return false;
    }
    const prefix = "native probe leaked ";
    const suffix = " Zig allocations";
    return std.mem.startsWith(u8, line, prefix) and std.mem.endsWith(u8, line, suffix) and
        line.len > prefix.len + suffix.len and digits(line[prefix.len .. line.len - suffix.len]);
}

fn digits(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

test "diagnostics admit only complete public failures and counts" {
    for ([_][]const u8{ "native probe failed: OutOfMemory", "callback probe failed: ProbeTimeout", "transport cycle 12 failed: ProbeTimeout", "native probe leaked 2 Zig allocations" }) |line| try std.testing.expect(safeDiagnostic(line));
    for ([_][]const u8{ "a=ice-pwd:synthetic", "native probe failed: a=ice-pwd:synthetic", "native probe failed: ProbeTimeout extra", "native probe leaked 2 Zig allocations a=ice-pwd:synthetic", "transport cycle -1 failed: Bad", "native probe failed: ", "\x1b[31mnative probe failed: Bad" }) |line| try std.testing.expect(!safeDiagnostic(line));
}
