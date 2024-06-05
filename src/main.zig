//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Dir = std.fs.Dir;
const File = std.fs.File;
const path = std.fs.path;

const ArgList = std.ArrayList([]u8);

const globals = @import("./globals.zig");
const utils = @import("./utils.zig");

const Configuration = @import("./settings.zig").Configuration;
const ReleaseManager = @import("./release_manager.zig").ReleaseManager;

const log = globals.log;

//-----------------------------------------------------------------------------

const Mode = enum { Zig, Zls, Ziege };
const Command = enum { Update, Install, Remove, SetDefault };
const LauncherArg = enum { Version };

const Args = struct {
    const Self = @This();

    allocator: Allocator,

    process_args: []const [:0]u8,

    launcher_args: ArgList,
    tool_args: ArgList,

    mode: Mode,

    pub fn init(allocator: Allocator) !Self {
        const args = try std.process.argsAlloc(allocator);

        const bin_name = path.basename(args[0]);
        const bin_name_hash = std.hash.Crc32.hash(bin_name);

        const mode: Mode = switch (bin_name_hash) {
            globals.ZIG_BIN_NAME_HASH => .Zig,
            globals.ZLS_BIN_NAME_HASH => .Zls,
            else => .Ziege,
        };

        var launcher_args = ArgList.init(allocator);
        try launcher_args.ensureTotalCapacity(args.len);

        var tool_args = ArgList.init(allocator);
        try tool_args.ensureTotalCapacity(args.len);

        // When we aren't running in 'ziege' mode, args that start with '+' are filtered and used
        // by the launcher. This will allow us to override zig versions, and perhaps some other
        // useful things.
        // Example: zig +version=0.13.0 build -Doptimize=ReleaseFast
        // Example: zig +version=0.12.0 build -Doptimize=ReleaseFast
        for (args[1..]) |arg| {
            const copy = try allocator.dupeZ(u8, arg);
            if (arg[0] == '+') {
                try launcher_args.append(copy);
            } else {
                try tool_args.append(copy);
            }
        }

        return Self{
            .allocator = allocator,
            .process_args = args,
            .launcher_args = launcher_args,
            .tool_args = tool_args,
            .mode = mode,
        };
    }

    pub fn parseLauncherArgs(self: *const Self) !std.AutoHashMap(LauncherArg, []const u8) {
        var map = std.AutoHashMap(LauncherArg, []const u8).init(self.allocator);
        for (self.launcher_args.items) |arg| {
            var entry = std.mem.splitSequence(u8, arg, "=");
            if (std.mem.eql(u8, entry.first(), "+version")) {
                const val = entry.next();
                if (val == null) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Version override requires an argument! Example: +version=0.12.0\n", .{});
                    std.process.exit(1);
                }
                try map.put(LauncherArg.Version, val.?);
            }
        }
        return map;
    }

    pub fn setToolPath(self: *Self, tool_path: []u8) !void {
        try self.tool_args.insert(0, tool_path);
    }

    pub fn deinit(self: *Self) void {
        std.process.argsFree(self.allocator, self.process_args);
        self.* = undefined;
    }
};

/// If there is a `.zigversion` file present in the current directory, we read the contents into a buffer.
fn loadZigVersion(config: *const Configuration) !?[]const u8 {
    var file = std.fs.cwd().openFile(globals.ZIGVERSION_FILENAME, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        else => return err,
    };
    defer file.close();

    const result = try file.readToEndAlloc(config.allocator, 64);

    // If a .zigversion file is edited manually instead of using ziege, then it's possible that
    // and editor will insert a newline at the end of the file. We trim the version here just in case.
    var eos: usize = result.len;
    for (0..result.len) |idx| {
        switch (result[idx]) {
            '\n', '\r' => {
                eos = idx;
                break;
            },
            else => continue,
        }
    }

    return try config.allocator.realloc(result, eos);
}

/// Write the specified version to `.zigversion` in the current working directory.
fn saveZigVersion(version: []const u8) !void {
    var file = try std.fs.cwd().createFile(globals.ZIGVERSION_FILENAME, .{});
    defer file.close();
    _ = try file.write(version);
}

/// Get the current nightly version from our cached release index, and update `.zigversion`.
fn pinToNightlyZig(releases: *ReleaseManager) ![]const u8 {
    const version = try releases.getZigNightlyVersion();
    try saveZigVersion(version);
    return version;
}

/// Top level for "zig" mode
pub fn zig(args: *Args, config: *Configuration) !void {
    log.debug("Running in Zig mode.", .{});

    const launcher_args = try args.parseLauncherArgs();

    var zig_version: []const u8 = undefined;
    if (launcher_args.contains(.Version)) {
        const override_version = launcher_args.getPtr(.Version);
        zig_version = try config.allocator.dupe(u8, override_version.?.*);
    } else {
        const repo_version = try loadZigVersion(config);
        if (repo_version == null) {
            // TODO: Get nightly *or* use a default version.
            // NOTE: It's possible that we end up instantiating the release manager twice and that feels itchy.
            var releases = try ReleaseManager.init(config);
            defer releases.deinit();
            zig_version = try pinToNightlyZig(&releases);
        } else {
            zig_version = repo_version.?;
        }
    }

    const zig_root_path = try config.locations.getZigRootPath(zig_version);
    if (!try utils.dirExists(zig_root_path)) {
        var releases = try ReleaseManager.init(config);
        defer releases.deinit();

        try releases.installZigVersion(zig_version);
    }

    const zig_bin_path = try std.fs.path.join(config.allocator, &.{ zig_root_path, globals.ZIG_BIN_NAME });
    log.debug("Running {s}", .{zig_bin_path});

    try args.setToolPath(zig_bin_path);

    var zig_proc = std.process.Child.init(args.tool_args.items, config.allocator);
    try zig_proc.spawn();
    const res = try zig_proc.wait();
    std.process.exit(res.Exited);
}

/// Top level for "zls" mode
pub fn zls(args: *Args, config: *Configuration) !void {
    log.debug("Running in Zls mode.", .{});
    _ = args;
    _ = config;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("ZLS mode is not yet implemented.\n", .{});
    std.process.exit(1);
}

/// Top level for "ziege" mode
pub fn ziege(args: *Args, config: *Configuration) !void {
    log.debug("Running in Ziege mode.", .{});
    _ = args;
    _ = config;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("Ziege mode is not yet implemented.\n", .{});
    std.process.exit(1);
}

/// Determine which mode we're running in and dispatch to appropriate top-level implementation
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args = try Args.init(allocator);
    defer args.deinit();

    var config = try Configuration.load(allocator);
    defer config.unload();

    switch (args.mode) {
        .Ziege => try ziege(&args, &config),
        .Zig => try zig(&args, &config),
        .Zls => try zls(&args, &config),
    }
}
