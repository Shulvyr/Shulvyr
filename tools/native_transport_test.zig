const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Driver = @import("native_transport.zig");
const Contract = @import("native-transport/Contract.zig");
const Runner = @import("native-transport/Runner.zig");
const Workspace = @import("native-transport/Workspace.zig");

test "CLI refuses ambiguous options and paths outside a named workspace" {
    try testing.expectEqualStrings("native-transport-zig", (try Driver.parseOptions(&.{})).workspace);
    try testing.expect((try Driver.parseOptions(&.{"--check-sources"})).check_sources);
    try testing.expectError(error.UnknownOption, Driver.parseOptions(&.{"--unknown"}));
    try testing.expectError(error.MissingOptionValue, Driver.parseOptions(&.{"--zig"}));
    try testing.expectError(error.MissingOptionValue, Driver.parseOptions(&.{ "--workspace", "" }));
    try testing.expectError(error.DuplicateOption, Driver.parseOptions(&.{ "--workspace", "one", "--workspace", "two" }));
    try testing.expectError(error.DuplicateOption, Driver.parseOptions(&.{ "--check-sources", "--check-sources" }));
    for ([_][]const u8{ "../other", "work/other", "C:/private", ".", "-flag", "one\ntwo" }) |name| try testing.expectError(error.InvalidNativeWorkspaceName, Driver.parseOptions(&.{ "--workspace", name }));
}

test "native manifest refuses unknown providers, revisions and submodule paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw = try Io.Dir.cwd().readFileAlloc(testing.io, "data/native-transport/sources.json", allocator, .limited(64 * 1024));
    _ = try Contract.Manifest.parse(allocator, raw);
    for ([_][2][]const u8{
        .{ "https://github.com/paullouisageneau/libdatachannel.git", "file:///tmp/unknown" },
        .{ "bdc5ff28e9d3b863144c94a677ecf5bf043aaf15", "main" },
        .{ "deps/plog", "../escape" },
        .{ "MPL-2.0", "Unknown" },
    }) |replacement| {
        const changed = try std.mem.replaceOwned(u8, allocator, raw, replacement[0], replacement[1]);
        try testing.expectError(error.InvalidNativeManifest, Contract.Manifest.parse(allocator, changed));
    }
}

test "header accepts LF and CRLF but rejects every other byte change" {
    const raw = "int rtcExample(void);\n#define EXAMPLE 1\n";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
    const expected = std.fmt.bytesToHex(hash, .lower);
    try Contract.verifyHeader(raw, &expected);
    try Contract.verifyHeader("int rtcExample(void);\r\n#define EXAMPLE 1\r\n", &expected);
    for ([_][]const u8{ "void rtcExample(void);\n#define EXAMPLE 1\n", raw ++ "\n", raw ++ "\x00", "int rtcExample(void);\n#define EXAMPLE 1", "int rtcExample(void);\r#define EXAMPLE 1\r" }) |changed| try testing.expectError(error.NativeHeaderMismatch, Contract.verifyHeader(changed, &expected));
}

test "gitlinks require exact mode, revision and path" {
    const revision = "94899e0b926ac1b0f4750bfbd495167b4a6ae9ef";
    try Contract.verifyGitlink("160000 commit " ++ revision ++ "\tdeps/plog\n", revision, "deps/plog");
    for ([_][]const u8{ "100644 blob " ++ revision ++ "\tdeps/plog", "160000 commit " ++ revision ++ "\tdeps/other", "160000 commit main\tdeps/plog", "160000 commit " ++ revision ++ "\tdeps/plog\nextra" }) |changed| try testing.expectError(error.UnexpectedNativeGitlink, Contract.verifyGitlink(changed, revision, "deps/plog"));
}

test "Visual Studio and package names accept supported platform spellings" {
    try testing.expectEqualStrings("Visual Studio 17 2022", try Contract.visualStudio("17.14.36218.1"));
    try testing.expectEqualStrings("Visual Studio 18 2026", try Contract.visualStudio("18.0.11205.1"));
    for ([_][]const u8{ "", "16.11", "19.0", "garbage", "18.bad", "18.0\nextra" }) |version| try testing.expectError(error.UnsupportedVisualStudio, Contract.visualStudio(version));
    try testing.expect(Contract.packageNameEqual("typing_extensions", "typing-extensions"));
    try testing.expect(Contract.packageNameEqual("Jinja2", "jinja2"));
    try testing.expect(!Contract.packageNameEqual("rpds", "rpds-py"));
}

test "zero-exit upstream output still requires one complete passing summary" {
    try testing.expectEqual(@as(u32, 11), try Contract.verifyUpstream("private SDP\nFinished 11 tests in 0.1s. Succeeded: 11. Failed: 0.\n"));
    try testing.expectEqual(@as(u32, 11), try Contract.verifyUpstream("*** Finished connectivity test\n*** Finished reliability test\nFinished 11 tests in 8s (8000 ms). Succeeded: 11. Failed: 0.\r\n"));
    for ([_][]const u8{ "", "Finished 0 tests in 0s. Succeeded: 0. Failed: 0.", "Finished 11 tests in 0s. Succeeded: 10. Failed: 1.", "Finished 11 tests in 0s. Succeeded: 11. Failed: 0. extra", "Finished 11 tests in 0s. Succeeded: 11. Failed: 0.\nFinished 11 tests in 0s. Succeeded: 11. Failed: 0." }) |invalid| try testing.expectError(error.NativeTestsFailed, Contract.verifyUpstream(invalid));
}

test "probe requires exact counters, one summary and all adapter tests" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const summary = try std.json.Stringify.valueAlloc(allocator, Contract.expected_probe, .{});
    const good = try std.mem.concat(allocator, u8, &.{ summary, "\n", Contract.adapter_summary, "\n" });
    try Contract.verifyProbe(allocator, good);
    const changed = try std.mem.replaceOwned(u8, allocator, good, "\"zig_allocation_leaks\":0", "\"zig_allocation_leaks\":1");
    try testing.expectError(error.NativeProbeFailed, Contract.verifyProbe(allocator, changed));
    try testing.expectError(error.NativeProbeFailed, Contract.verifyProbe(allocator, summary));
    try testing.expectError(error.NativeProbeFailed, Contract.verifyProbe(allocator, try std.mem.concat(allocator, u8, &.{ good, summary, "\n" })));
    const incomplete = "{\"cycles\":3}\n10/10 tests passed";
    try testing.expectError(error.NativeProbeFailed, Contract.verifyProbe(allocator, incomplete));
    const stale = try std.mem.concat(allocator, u8, &.{ summary, "\n10/10 tests passed\n" });
    try testing.expectError(error.NativeProbeFailed, Contract.verifyProbe(allocator, stale));
}

test "workspace rejects unowned directories and mismatched source pins" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owned = try Workspace.openIn(allocator, testing.io, temporary.dir, "owned", "synthetic-pin");
    try testing.expectError(error.WouldBlock, Workspace.openIn(allocator, testing.io, temporary.dir, "owned", "synthetic-pin"));
    try owned.directory.createDir(testing.io, "evidence.json", .default_dir);
    try testing.expectError(error.UnsafeNativePath, owned.write(testing.io, "evidence.json", "success"));
    owned.close(testing.io);
    var reopened = try Workspace.openIn(allocator, testing.io, temporary.dir, "owned", "synthetic-pin");
    reopened.close(testing.io);
    try testing.expectError(error.UnownedNativeWorkspace, Workspace.openIn(allocator, testing.io, temporary.dir, "owned", "changed-pin"));
    try temporary.dir.createDir(testing.io, "work/unowned", .default_dir);
    try testing.expectError(error.FileNotFound, Workspace.openIn(allocator, testing.io, temporary.dir, "unowned", "synthetic-pin"));
}

test "workspace containment rejects sibling prefixes and parent traversal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = if (@import("builtin").os.tag == .windows) "C:/owned/work" else "/owned/work";
    const child = try std.fs.path.join(arena.allocator(), &.{ root, "native" });
    try Workspace.beneath(arena.allocator(), root, child);
    try testing.expectError(error.UnsafeNativePath, Workspace.beneath(arena.allocator(), root, root));
    try testing.expectError(error.UnsafeNativePath, Workspace.beneath(arena.allocator(), root, try std.fmt.allocPrint(arena.allocator(), "{s}-other/native", .{root})));
}

test "private failing child retains raw evidence without disclosing ICE" {
    const helper = try Io.Dir.cwd().realPathFileAlloc(testing.io, @import("test_options").child, testing.allocator);
    defer testing.allocator.free(helper);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    var public: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&public);
    var runner: Runner = .{ .gpa = testing.allocator, .io = testing.io, .logs = temporary.dir, .cwd = path, .output = &writer };
    try testing.expectError(error.CommandFailed, runner.run(&.{ helper, "private-failure" }, .{ .private = true, .log = "private.log" }));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "native probe failed: ProbeTimeout") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "ice-pwd") == null);
    const raw = try temporary.dir.readFileAlloc(testing.io, "private.log", testing.allocator, .limited(4096));
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "a=ice-pwd:synthetic") != null);
}

test "process deadline covers open pipes and closed-pipe stalls" {
    const helper = try Io.Dir.cwd().realPathFileAlloc(testing.io, @import("test_options").child, testing.allocator);
    defer testing.allocator.free(helper);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    var public: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&public);
    var runner: Runner = .{ .gpa = testing.allocator, .io = testing.io, .logs = temporary.dir, .cwd = path, .output = &writer };
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "incomplete.log", .data = "stale successful output" });
    try testing.expectError(error.CommandTimeout, runner.run(&.{ helper, "stall" }, .{ .seconds = 1, .log = "incomplete.log" }));
    const incomplete = try temporary.dir.readFileAlloc(testing.io, "incomplete.log", testing.allocator, .limited(128));
    defer testing.allocator.free(incomplete);
    try testing.expectEqual(@as(usize, 0), incomplete.len);
    for ([_][]const u8{ "stall", "closed-stall" }) |mode| try testing.expectError(error.CommandTimeout, runner.run(&.{ helper, mode }, .{ .seconds = 1 }));
    const reached = try temporary.dir.readFileAlloc(testing.io, "closed-pipes", testing.allocator, .limited(32));
    defer testing.allocator.free(reached);
    try testing.expectEqualStrings("reached", reached);
}

test "child output and log names stay bounded" {
    const helper = try Io.Dir.cwd().realPathFileAlloc(testing.io, @import("test_options").child, testing.allocator);
    defer testing.allocator.free(helper);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    var public: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&public);
    var runner: Runner = .{ .gpa = testing.allocator, .io = testing.io, .logs = temporary.dir, .cwd = path, .output = &writer };
    try testing.expectError(error.StreamTooLong, runner.run(&.{ helper, "flood" }, .{ .stream_limit = 1024 }));
    try testing.expectError(error.InvalidLogName, runner.run(&.{ helper, "private-failure" }, .{ .log = "../escape" }));
}

test {
    _ = Runner;
    _ = @import("reference_sources.zig");
}
