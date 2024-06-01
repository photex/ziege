const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const zig_index_url = "https://ziglang.org/download/index.json";
const zig_bin_name_hash = hash.Crc32.hash("zig");

const zls_index_url = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";
const zls_bin_name_hash = hash.Crc32.hash("zls");

const Mode = enum { Zig, Zls, Ziege };
const Command = enum { Update, Fetch, SetDefault };

const Dir = std.fs.Dir;
const File = std.fs.File;

const ArgList = std.ArrayList([:0]const u8);

const log = std.log.scoped(.ziege);

const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    else => @compileError("Unsupported CPU Architecture"),
};

const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};

const url_platform = os ++ "-" ++ arch;
const json_platform = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

/// Read the contents of the file specified by file_path and return a u8 slice with it's contents.
fn readFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

/// Load a zig release index
fn loadToolchainIndex(allocator: Allocator) !json.Parsed(json.Value) {
    log.warn("**TODO** toolchain index is still only read from disk at cwd.", .{});
    const index_text = try readFile(allocator, "zig_index.json");
    return try json.parseFromSlice(std.json.Value, allocator, index_text, .{});
}

fn findTargetZigVersion(allocator: Allocator) ![]u8 {
    log.debug("**TODO** zig toolchain version is only search for in cwd.", .{});
    return try readFile(allocator, ".zigversion");
}

// For args that start with '+' we interpret as arguments
// for us rather than the tools we proxy.
fn extract_args(allocator: Allocator, launcher_args: *ArgList, argv: *ArgList) !void {
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try argv.ensureTotalCapacity(args.len);
    try launcher_args.ensureTotalCapacity(args.len);

    // We preserve the path to the executable that got run in the launcher
    // args so that we can figure out what mode to operate in etc.
    try launcher_args.append(args[0]);
    try argv.append(args[0]);

    for (args[1..]) |arg| {
        if (arg[0] == '+') {
            try launcher_args.append(arg);
        } else {
            try argv.append(arg);
        }
    }
}

const Locations = struct {
    const Self = @This();
    home: []u8,
    config: []u8,
    toolchains: []u8,

    pub fn init(allocator: Allocator) !Self {
        const home = try std.process.getEnvVarOwned(allocator, home_var);
        const config = try std.fs.path.join(allocator, &.{ home, ".zig" });
        const toolchains = try std.fs.path.join(allocator, &.{ config, "toolchains" });

        log.debug("CONFIG: {s}", .{config});
        log.debug("TOOLCHAINS: {s}", .{toolchains});
        return Self{
            .home = home,
            .config = config,
            .toolchains = toolchains,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.home);
        allocator.free(self.config);
        allocator.free(self.toolchains);
    }
};

const Launcher = struct {
    const Self = @This();

    allocator: Allocator,
    launcher_args: ArgList,
    argv: ArgList,
    mode: Mode,
    locations: Locations,

    pub fn init(allocator: Allocator) !Self {
        log.debug("Initializing...", .{});

        var launcher_args = ArgList.init(allocator);
        var argv = ArgList.init(allocator);

        try extract_args(allocator, &launcher_args, &argv);

        const bin_name = path.basename(launcher_args.items[0]);
        const bin_name_hash = hash.Crc32.hash(bin_name);

        const mode: Mode = switch (bin_name_hash) {
            zig_bin_name_hash => .Zig,
            zls_bin_name_hash => .Zls,
            else => .Ziege,
        };

        const locations = try Locations.init(allocator);

        const index = try loadToolchainIndex(allocator);
        _ = index;

        return Self{
            .allocator = allocator,
            .launcher_args = launcher_args,
            .argv = argv,
            .mode = mode,
            .locations = locations,
        };
    }

    pub fn deinit(self: *Self) !void {
        log.debug("Cleaning up...", .{});
        //std.process.argsFree(self.allocator, self.argv);
        self.locations.deinit(self.allocator);
        self.launcher_args.deinit();
        self.argv.deinit();
    }
};

fn zig_mode(launcher: Launcher) !void {
    log.debug("We are running in zig mode!", .{});

    const zigBin = "/home/chip/.local/bin/zig";

    var argv = ArgList.init(launcher.allocator);
    defer argv.deinit();
    try argv.append(zigBin);

    try extract_args(launcher, &argv);

    var zig = std.ChildProcess.init(argv.items, launcher.allocator);

    try zig.spawn();

    log.debug("Spawned {d}", .{zig.id});

    const term = try zig.wait();
    if (term != .Exited) {
        log.err("There was an error running zig.", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const stat = gpa.deinit();
        if (stat == .leak) {
            log.err("Memory leak detected!", .{});
            std.process.exit(1);
        }
    }

    var launcher = try Launcher.init(gpa.allocator());

    defer launcher.deinit() catch @panic("Unrecoverable error during shutdown!");
}
