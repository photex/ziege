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

const globals = @import("./globals.zig");
const utils = @import("./utils.zig");

const Configuration = @import("./settings.zig").Configuration;
const ReleaseManager = @import("./release_manager.zig").ReleaseManager;

const log = globals.log;

const VERSION = "0.2.0-dev";

//-----------------------------------------------------------------------------

const Mode = enum { Zig, Zls, Ziege };
const Command = enum { Update, Install, Remove, SetDefault };
const LauncherArg = enum { UseVersion, SetVersion };

const ArgList = std.ArrayList([]u8);
const LauncherArgs = std.AutoHashMap(LauncherArg, []const u8);

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

        var mode: Mode = switch (bin_name_hash) {
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
                // To help address the edge-case of running ziege under cmd.exe on Windows, I'm adding these
                // escape hatches to activate the other modes without needing to copy or symlink the binary.
                // This should let us write batch scripts as part of the release process for windows and it
                // should work equally for powershell and cmd.exe
                if (std.mem.eql(u8, "+zig", arg)) {
                    mode = .Zig;
                } else if (std.mem.eql(u8, "+zls", arg)) {
                    mode = .Zls;
                } else {
                    try launcher_args.append(copy);
                }
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

    pub fn parseLauncherArgs(self: *const Self) !LauncherArgs {
        var map = LauncherArgs.init(self.allocator);
        for (self.launcher_args.items) |arg| {
            const crc = std.hash.Crc32.hash;
            var entry = std.mem.splitSequence(u8, arg, "=");
            switch (crc(entry.first())) {
                crc("+version") => {
                    const val = entry.next();
                    if (val == null) {
                        const stderr = std.io.getStdErr().writer();
                        try stderr.print("Version override requires an argument! Example: +version=0.12.0\n", .{});
                        std.process.exit(1);
                    }
                    try map.put(LauncherArg.UseVersion, val.?);
                },
                crc("+set-version") => {
                    const val = entry.next();
                    if (val == null) {
                        const stderr = std.io.getStdErr().writer();
                        try stderr.print("Setting the version requires an argument! Example: +set-version=0.12.0\n", .{});
                        std.process.exit(1);
                    }
                    try map.put(LauncherArg.SetVersion, val.?);
                },
                else => {},
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

fn zigRootPath(launcher_args: *const LauncherArgs, config: *Configuration) ![]const u8 {
    var zig_version: []const u8 = undefined;
    if (launcher_args.contains(.UseVersion)) {
        const override_version = launcher_args.getPtr(.UseVersion);
        zig_version = try config.allocator.dupe(u8, override_version.?.*);
    } else if (launcher_args.contains(.SetVersion)) {
        const new_version = launcher_args.getPtr(.SetVersion);
        zig_version = try config.allocator.dupe(u8, new_version.?.*);
        try saveZigVersion(zig_version);
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

    return zig_root_path;
}

fn spawnTool(argv: *ArgList, config: *Configuration) !u8 {
    var subproc = std.process.Child.init(argv.items, config.allocator);
    try subproc.spawn();
    const res = try subproc.wait();
    return res.Exited;
}

/// Top level for our proxy modes
pub fn runAsProxy(args: *Args, config: *Configuration, bin_name: []const u8) !void {
    const launcher_args = try args.parseLauncherArgs();

    const zig_root_path = try zigRootPath(&launcher_args, config);
    const tool_path = try std.fs.path.join(config.allocator, &.{ zig_root_path, bin_name });
    log.debug("Running {s}", .{tool_path});

    try args.setToolPath(tool_path);

    const return_code = try spawnTool(&args.tool_args, config);
    std.process.exit(return_code);
}

const USAGE = "Usage: ziege [list | add <version> | remove <version> | set-version <version> | help]";

/// Top level for "ziege" mode
pub fn ziege(args: *Args, config: *Configuration) !void {
    log.debug("Running in Ziege mode.", .{});

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.process_args.len == 1) {
        try stdout.print("{s}", .{USAGE});
        std.process.exit(1);
    }

    const crc = std.hash.Crc32.hash;

    switch (crc(args.process_args[1])) {
        crc("list") => {
            const pkg_dir = try std.fs.openDirAbsolute(config.locations.zig_pkgs, .{ .iterate = true });
            var iter = pkg_dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .directory) {
                    try stdout.print("{s}\n", .{entry.name});
                }
            }
        },
        crc("add") => {
            if (args.process_args.len != 3) {
                try stderr.print("No version specified!\nUsage: ziege add <version>\n", .{});
                std.process.exit(1);
            }
            const zig_version = args.process_args[2];

            const zig_root_path = try config.locations.getZigRootPath(zig_version);
            if (try utils.dirExists(zig_root_path)) {
                try stderr.print("Zig {s} is already installed.\n", .{zig_version});
                std.process.exit(1);
            }

            var releases = try ReleaseManager.init(config);
            defer releases.deinit();

            try releases.installZigVersion(zig_version);
        },
        crc("remove") => {
            if (args.process_args.len != 3) {
                try stderr.print("No version specified!\nUsage: ziege remove <version>\n", .{});
                std.process.exit(1);
            }
            const zig_version = args.process_args[2];
            const zig_root_path = try config.locations.getZigRootPath(zig_version);
            if (!try utils.dirExists(zig_root_path)) {
                try stderr.print("Zig {s} is not installed!\n", .{zig_version});
                std.process.exit(1);
            }

            var releases = try ReleaseManager.init(config);
            defer releases.deinit();

            try releases.uninstallZigVersion(zig_version);
        },
        crc("set-version") => {
            if (args.process_args.len != 3) {
                try stderr.print("No version specified!\nUsage: ziege set-version <version>\n", .{});
                std.process.exit(1);
            }
            const zig_version = args.process_args[2];
            const zig_root_path = try config.locations.getZigRootPath(zig_version);
            if (!try utils.dirExists(zig_root_path)) {
                var releases = try ReleaseManager.init(config);
                defer releases.deinit();

                try releases.installZigVersion(zig_version);
            }
            try saveZigVersion(zig_version);
        },
        crc("version") => {
            try stdout.print("{s}\n", .{VERSION});
        },
        crc("help") => {
            const help_msg =
                \\  list - List installed Zig versions.
                \\  add <version> - Install the specified Zig version.
                \\  remove <version> - Remove the specified Zig version.
                \\  set-version <version> - Update .zigversion and install the specified version if needed.
            ;
            try stdout.print("Ziege v{s}\n{s}\n\n{s}\n\n", .{ VERSION, USAGE, help_msg });
        },
        else => {
            try stdout.print("{s}\n", .{USAGE});
            std.process.exit(1);
        },
    }
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
        .Zig => {
            log.debug("Running in Zig mode.", .{});
            try runAsProxy(&args, &config, globals.ZIG_BIN_NAME);
        },
        .Zls => {
            log.debug("Running in Zls mode.", .{});
            try runAsProxy(&args, &config, globals.ZLS_BIN_NAME);
        },
    }
}
