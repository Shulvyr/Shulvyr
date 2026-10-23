const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Contract = @import("native-transport/Contract.zig");
const Runner = @import("native-transport/Runner.zig");
const Workspace = @import("native-transport/Workspace.zig");
const Json = @import("reference_sources.zig");

const Options = struct {
    workspace: []const u8 = "native-transport-zig",
    zig: []const u8 = @import("native_options").zig,
    cmake: []const u8 = "cmake",
    python: []const u8 = "python",
    check_sources: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    var buffer: [2048]u8 = undefined;
    var output: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) catch |err| {
        try output.interface.print("Invalid native driver arguments: {s}\n", .{@errorName(err)});
        try output.interface.flush();
        return 1;
    };
    execute(init, &output.interface, options) catch |err| {
        try output.interface.print("Native driver failed: {s}\n", .{@errorName(err)});
        try output.interface.flush();
        return 1;
    };
    try output.interface.flush();
    return 0;
}

pub fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var used: u8 = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--check-sources")) {
            if (options.check_sources) return error.DuplicateOption;
            options.check_sources = true;
            continue;
        }
        const names = [_][]const u8{ "--workspace", "--zig", "--cmake", "--python" };
        var matched = false;
        for (names, 0..) |name, bit| {
            if (!std.mem.eql(u8, argument, name)) continue;
            const mask = @as(u8, 1) << @as(u3, @intCast(bit));
            if (used & mask != 0) return error.DuplicateOption;
            used |= mask;
            index += 1;
            if (index == args.len or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.MissingOptionValue;
            switch (bit) {
                0 => options.workspace = args[index],
                1 => options.zig = args[index],
                2 => options.cmake = args[index],
                3 => options.python = args[index],
                else => unreachable,
            }
            matched = true;
            break;
        }
        if (!matched) return error.UnknownOption;
    }
    try Workspace.validName(options.workspace);
    return options;
}

fn execute(init: std.process.Init, output: *Io.Writer, options: Options) !void {
    if (builtin.cpu.arch != .x86_64 or (builtin.os.tag != .windows and builtin.os.tag != .linux)) return error.UnsupportedNativeHost;
    const allocator = init.arena.allocator();
    const io = init.io;
    const cwd = Io.Dir.cwd();
    const root = try cwd.realPathFileAlloc(io, ".", allocator);
    const raw = try cwd.readFileAlloc(io, "data/native-transport/sources.json", allocator, .limited(64 * 1024));
    const manifest = try Contract.Manifest.parse(allocator, raw);
    const requirements = try cwd.readFileAlloc(io, "data/native-transport/python-requirements.txt", allocator, .limited(16 * 1024));
    var input_hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    input_hash.update(&manifest.sha256);
    input_hash.update(requirements);
    var inputs: [32]u8 = undefined;
    input_hash.final(&inputs);
    const input_fingerprint = std.fmt.bytesToHex(inputs, .lower);
    var workspace = try Workspace.open(allocator, io, options.workspace, &input_fingerprint);
    defer workspace.close(io);
    var runner: Runner = .{ .gpa = init.gpa, .io = io, .logs = workspace.directory, .cwd = root, .output = output };
    if (!options.check_sources) try workspace.write(io, "evidence.json", "{\"schema\":1,\"status\":\"in_progress\"}\n");
    const zig = try program(allocator, io, init.environ_map, options.zig);
    const version = try text(allocator, &runner, &.{ zig, "version" });
    const required = std.mem.trim(u8, try cwd.readFileAlloc(io, ".zigversion", allocator, .limited(64)), "\r\n ");
    if (!std.mem.eql(u8, version, required)) return error.WrongZigCompiler;
    const git = try program(allocator, io, init.environ_map, "git");
    const hooks = try workspace.child(allocator, io, "empty-hooks");
    var hook_directory = try cwd.openDir(io, hooks, .{ .iterate = true });
    defer hook_directory.close(io);
    var iterator = hook_directory.iterate();
    if (try iterator.next(io) != null) return error.NonemptyHooksDirectory;
    const git_args = &.{ git, "-c", try std.fmt.allocPrint(allocator, "core.hooksPath={s}", .{hooks}), "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never", "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false", "-c", "core.fsmonitor=false" };
    const sources = try workspace.child(allocator, io, "sources");
    try phase(output, "Verify pinned native sources");
    const channel = try prepare(allocator, &runner, git_args, sources, "libdatachannel", manifest.channel, &Contract.channel_dependencies);
    const tls = try prepare(allocator, &runner, git_args, sources, "mbedtls", manifest.tls, &Contract.tls_dependencies);
    const header = try cwd.readFileAlloc(io, try join(allocator, channel, "include/rtc/rtc.h"), allocator, .limited(256 * 1024));
    try Contract.verifyHeader(header, try Contract.string(manifest.channel, "header_lf_sha256"));
    try phase(output, "Verified 6 native source revisions, clean checkouts and C API header");
    if (options.check_sources) return;
    const cmake = try program(allocator, io, init.environ_map, options.cmake);
    const python = try program(allocator, io, init.environ_map, options.python);
    const python_version = try text(allocator, &runner, &.{ python, "--version" });
    if (!std.mem.startsWith(u8, python_version, "Python 3.14.")) return error.WrongNativeGeneratorPython;
    const requirements_hash = try verifyPackages(allocator, &runner, python, requirements);
    const generator = if (builtin.os.tag == .windows) blk: {
        const base = init.environ_map.get("ProgramFiles(x86)") orelse "C:/Program Files (x86)";
        const vswhere = try join(allocator, base, "Microsoft Visual Studio/Installer/vswhere.exe");
        const installed = try text(allocator, &runner, &.{ vswhere, "-latest", "-products", "*", "-version", "[17.0,19.0)", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationVersion" });
        break :blk try Contract.visualStudio(installed);
    } else "Ninja";
    const generator_args: []const []const u8 = if (builtin.os.tag == .windows) &.{ "-G", generator, "-A", "x64" } else &.{ "-G", generator };
    const tls_build = try workspace.child(allocator, io, "mbedtls-build");
    const tls_prefix = try workspace.child(allocator, io, "mbedtls-install");
    const native_build = try workspace.child(allocator, io, "channel-build");
    const prefix = try workspace.child(allocator, io, "native-prefix");
    try phase(output, "Build Mbed TLS with its pinned upstream generators");
    try command(allocator, &runner, &.{ cmake, "-S", tls, "-B", tls_build }, generator_args, &.{
        "-DENABLE_PROGRAMS=OFF",                             "-DENABLE_TESTING=OFF",                                    "-DGEN_FILES=ON",
        "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",                  "-DUSE_STATIC_MBEDTLS_LIBRARY=ON",                         "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DCMAKE_BUILD_TYPE=Release",                        "-DCMAKE_INSTALL_LIBDIR=lib",                              "-DMBEDTLS_CONFIG_SET=MBEDTLS_SSL_DTLS_SRTP",
        try define(allocator, "Python3_EXECUTABLE", python), try define(allocator, "CMAKE_INSTALL_PREFIX", tls_prefix),
    }, "mbedtls-configure.log");
    try runner.step(&.{ cmake, "--build", tls_build, "--config", "Release", "--parallel", "4" }, .{ .log = "mbedtls-build.log" });
    try runner.step(&.{ cmake, "--install", tls_build, "--config", "Release" }, .{ .log = "mbedtls-install.log" });
    try phase(output, "Build libdatachannel and upstream tests");
    try command(allocator, &runner, &.{ cmake, "-S", channel, "-B", native_build }, generator_args, &.{
        "-DNO_MEDIA=ON",              "-DNO_WEBSOCKET=ON",          "-DNO_EXAMPLES=ON",                                     "-DNO_TESTS=OFF",
        "-DUSE_MBEDTLS=ON",           "-DBUILD_SHARED_LIBS=ON",     "-DBUILD_SHARED_DEPS_LIBS=OFF",                         "-DENABLE_LOCALHOST_ADDRESS=ON",
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_LIBDIR=lib", try define(allocator, "CMAKE_PREFIX_PATH", tls_prefix), try define(allocator, "CMAKE_INSTALL_PREFIX", prefix),
    }, "native-configure.log");
    try runner.step(&.{ cmake, "--build", native_build, "--config", "Release", "--target", "datachannel", "datachannel-tests", "--parallel", "4" }, .{ .log = "native-build.log" });
    try runner.step(&.{ cmake, "--install", native_build, "--config", "Release" }, .{ .log = "native-install.log" });
    try phase(output, "Run upstream native tests with private logs");
    const tests = try join(allocator, native_build, if (builtin.os.tag == .windows) "Release/tests.exe" else "tests");
    var testing = runner;
    testing.cwd = workspace.path;
    const native_output = try testing.run(&.{tests}, .{ .log = "native-tests.log", .seconds = 180, .private = true });
    defer init.gpa.free(native_output);
    const count = try Contract.verifyUpstream(native_output);
    try output.print("Upstream native tests passed: {d}\n", .{count});
    for ([_][]const u8{ "debug", "safe" }) |mode| {
        try output.print("Run Zig C API probe: {s}\n", .{mode});
        try output.flush();
        const probe = try runner.run(&.{ zig, "build", "test-native-transport", try define(allocator, "native-transport-prefix", prefix), try define(allocator, "optimize", mode), "--summary", "all" }, .{ .log = try std.fmt.allocPrint(allocator, "probe-{s}.log", .{mode}), .seconds = 300, .private = true });
        defer init.gpa.free(probe);
        try Contract.verifyProbe(allocator, probe);
        try output.print("Native adapter tests passed: 10 ({s})\n", .{mode});
    }
    const library = try join(allocator, prefix, if (builtin.os.tag == .windows) "bin/datachannel.dll" else "lib/libdatachannel.so");
    const bytes = try cwd.readFileAlloc(io, library, allocator, .limited(128 * 1024 * 1024));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const evidence = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = 1,
        .status = "success",
        .driver = "Shulvyr Zig native driver",
        .system = @tagName(builtin.os.tag),
        .zig = version,
        .sources = try Json.parse(allocator, raw),
        .source_manifest_sha256 = &manifest.sha256,
        .workspace_inputs_sha256 = &input_fingerprint,
        .cmake = try text(allocator, &runner, &.{ cmake, "--version" }),
        .generator = generator,
        .python = python_version,
        .generator_requirements_sha256 = requirements_hash,
        .library_sha256 = std.fmt.bytesToHex(hash, .lower),
        .upstream_tests = count,
        .native_adapter_tests = 10,
        .zig_probes = [_][]const u8{ "debug", "safe" },
    }, .{ .whitespace = .indent_2 });
    try workspace.write(io, "evidence.json", evidence);
    try phase(output, "Native transport probe passed. No Minecraft client was tested.");
}

fn prepare(allocator: Allocator, runner: *Runner, git: []const []const u8, sources: []const u8, name: []const u8, entry: std.json.Value, children: []const Contract.Dependency) ![]const u8 {
    const path = try join(allocator, sources, name);
    var fresh = true;
    Io.Dir.cwd().createDir(runner.io, path, Workspace.permissions(true)) catch |err| switch (err) {
        error.PathAlreadyExists => fresh = false,
        else => return err,
    };
    const real = try Io.Dir.cwd().realPathFileAlloc(runner.io, path, allocator);
    try Workspace.beneath(allocator, sources, real);
    if ((try Io.Dir.cwd().statFile(runner.io, path, .{ .follow_symlinks = false })).kind != .directory) return error.UnsafeNativePath;
    const repository = try Contract.string(entry, "repository");
    const revision = try Contract.string(entry, "revision");
    if (fresh) {
        try gitStep(allocator, runner, git, &.{ "init", path });
        try gitStep(allocator, runner, git, &.{ "-C", path, "remote", "add", "origin", repository });
        try gitStep(allocator, runner, git, &.{ "-C", path, "fetch", "--depth=1", "origin", revision });
        try gitStep(allocator, runner, git, &.{ "-C", path, "checkout", "--detach", revision });
    }
    try verifyCheckout(allocator, runner, git, path, revision);
    const origin = try gitText(allocator, runner, git, &.{ "-C", path, "remote", "get-url", "origin" });
    if (!std.mem.eql(u8, origin, repository)) return error.UnexpectedNativeOrigin;
    const submodules = try Contract.field(entry, "submodules");
    for (children) |child| {
        const dependency = try Contract.field(submodules, child.path);
        const wanted = try Contract.string(dependency, "revision");
        const link = try gitText(allocator, runner, git, &.{ "-C", path, "ls-tree", "HEAD", child.path });
        try Contract.verifyGitlink(link, wanted, child.path);
        const key = try std.fmt.allocPrint(allocator, "submodule.{s}.url", .{child.path});
        const url = try gitText(allocator, runner, git, &.{ "-C", path, "config", "--file", ".gitmodules", "--get", key });
        if (!std.mem.eql(u8, url, child.repository)) return error.UnexpectedNativeSubmodule;
        const destination = try join(allocator, path, child.path);
        if (Io.Dir.cwd().access(runner.io, try join(allocator, destination, ".git"), .{})) |_| {} else |err| switch (err) {
            error.FileNotFound => try gitStep(allocator, runner, git, &.{ "-C", path, "submodule", "update", "--init", "--checkout", "--", child.path }),
            else => return err,
        }
        const resolved = try Io.Dir.cwd().realPathFileAlloc(runner.io, destination, allocator);
        try Workspace.beneath(allocator, path, resolved);
        try verifyCheckout(allocator, runner, git, destination, wanted);
    }
    return path;
}

fn verifyCheckout(allocator: Allocator, runner: *Runner, git: []const []const u8, path: []const u8, revision: []const u8) !void {
    const actual = try gitText(allocator, runner, git, &.{ "-C", path, "rev-parse", "HEAD" });
    if (!std.mem.eql(u8, actual, revision)) return error.UnexpectedNativeRevision;
    const status = try gitText(allocator, runner, git, &.{ "-C", path, "status", "--porcelain", "--untracked-files=normal" });
    if (status.len != 0) return error.DirtyNativeCheckout;
}
fn gitText(allocator: Allocator, runner: *Runner, prefix: []const []const u8, args: []const []const u8) ![]const u8 {
    return text(allocator, runner, try std.mem.concat(allocator, []const u8, &.{ prefix, args }));
}
fn gitStep(allocator: Allocator, runner: *Runner, prefix: []const []const u8, args: []const []const u8) !void {
    try runner.step(try std.mem.concat(allocator, []const u8, &.{ prefix, args }), .{ .log = "source-command.log" });
}
fn text(allocator: Allocator, runner: *Runner, args: []const []const u8) ![]const u8 {
    const bytes = try runner.run(args, .{ .seconds = 60, .stream_limit = 128 * 1024 });
    defer runner.gpa.free(bytes);
    return allocator.dupe(u8, std.mem.trim(u8, bytes, "\r\n \t"));
}
fn command(allocator: Allocator, runner: *Runner, first: []const []const u8, second: []const []const u8, third: []const []const u8, log: []const u8) !void {
    try runner.step(try std.mem.concat(allocator, []const u8, &.{ first, second, third }), .{ .log = log });
}
fn join(allocator: Allocator, first: []const u8, second: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ first, second });
}
fn define(allocator: Allocator, name: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "-D{s}={s}", .{ name, value });
}
fn phase(output: *Io.Writer, message: []const u8) !void {
    try output.print("{s}\n", .{message});
    try output.flush();
}

fn program(allocator: Allocator, io: Io, environment: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "/\\") != null) return cwd.realPathFileAlloc(io, name, allocator);
    const paths = environment.get("PATH") orelse environment.get("Path") orelse return error.NativeProgramNotFound;
    const file = if (builtin.os.tag == .windows and !std.ascii.endsWithIgnoreCase(name, ".exe")) try std.fmt.allocPrint(allocator, "{s}.exe", .{name}) else name;
    var directories = std.mem.splitScalar(u8, paths, if (builtin.os.tag == .windows) ';' else ':');
    while (directories.next()) |directory| {
        if (directory.len == 0) continue;
        const candidate = try join(allocator, directory, file);
        const resolved = cwd.realPathFileAlloc(io, candidate, allocator) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        if ((try cwd.statFile(io, resolved, .{})).kind == .file) return resolved;
    }
    return error.NativeProgramNotFound;
}

fn verifyPackages(allocator: Allocator, runner: *Runner, python: []const u8, requirements: []const u8) ![64]u8 {
    const listing = try text(allocator, runner, &.{ python, "-m", "pip", "list", "--format=json", "--disable-pip-version-check" });
    const packages = try Json.parse(allocator, listing);
    if (packages != .array) return error.InvalidNativePythonPackages;
    var lines = std.mem.splitScalar(u8, requirements, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\\");
        const separator = std.mem.indexOf(u8, line, "==") orelse continue;
        const name = line[0..separator];
        const wanted = line[separator + 2 ..];
        var matches: usize = 0;
        for (packages.array.items) |package| {
            if (!Contract.packageNameEqual(try Contract.string(package, "name"), name)) continue;
            if (!std.mem.eql(u8, try Contract.string(package, "version"), wanted)) return error.WrongNativePythonPackage;
            matches += 1;
        }
        if (matches != 1) return error.MissingNativePythonPackage;
        count += 1;
    }
    if (count != 8) return error.InvalidNativePythonRequirements;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(requirements, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
