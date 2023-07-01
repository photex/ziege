const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;

const Mode = enum { Zig, Zls, Ziege };

const Args = [][:0]u8;
const ArgList = std.ArrayList([:0]const u8);

const log = std.log.scoped(.ziege);

fn getHomeDirectory(allocator: Allocator) ![]u8 {
    switch (native_os) {
        .windows => return try std.process.getEnvVarOwned(allocator, "USERPROFILE"),
        else => return try std.process.getEnvVarOwned(allocator, "HOME"),
    }
}

const Locations = struct {
    const Self = @This();
    home: []u8,
    config: []u8,
    toolchains: []u8,

    pub fn init(allocator: Allocator) !Self {
        const home = try getHomeDirectory(allocator);
        const config = try std.fs.path.join(allocator, &.{ home, ".zig" });
        const toolchains = try std.fs.path.join(allocator, &.{ config, "toolchains" });
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
    args: Args,
    mode: Mode,
    locations: Locations,

    pub fn init(allocator: Allocator) !Self {
        log.debug("Initializing...", .{});
        var args = try std.process.argsAlloc(allocator);

        const zigBinNameHash = comptime hash.Crc32.hash("zig");
        const zlsBinNameHash = comptime hash.Crc32.hash("zls");

        const binName = path.basename(args[0]);
        const binNameHash = hash.Crc32.hash(binName);

        return Self{
            .allocator = allocator,
            .args = args,
            .mode = switch (binNameHash) {
                zigBinNameHash => .Zig,
                zlsBinNameHash => .Zls,
                else => .Ziege,
            },
            .locations = try Locations.init(allocator),
        };
    }

    pub fn deinit(self: *Self) !void {
        log.debug("Cleaning up...", .{});
        std.process.argsFree(self.allocator, self.args);
        self.locations.deinit(self.allocator);
    }
};

// For args that start with '+' we interpret as arguments
// for us rather than the tools we proxy.
fn extract_args(app: Launcher, argv: *ArgList) !void {
    try argv.ensureTotalCapacity(app.args.len);
    for (app.args[1..]) |arg| {
        if (arg[0] == '+') {
            log.debug("Found an arg for ziege: {s}", .{arg});
        } else {
            try argv.append(arg);
        }
    }
}

fn zig_mode(app: Launcher) !void {
    log.debug("We are running in zig mode!", .{});

    const zigBin = "/home/chip/.local/bin/zig";

    var argv = ArgList.init(app.allocator);
    defer argv.deinit();
    try argv.append(zigBin);

    try extract_args(app, &argv);

    var zig = std.ChildProcess.init(argv.items, app.allocator);

    try zig.spawn();

    log.debug("Spawned {d}", .{zig.id});

    const term = try zig.wait();
    if (term != .Exited) {
        log.err("There was an error running zig.", .{});
    }
}

fn zls_mode(app: Launcher) !void {
    log.debug("We are running in zls mode!", .{});
    var argv = ArgList.init(app.allocator);
    defer argv.deinit();
    try extract_args(app, &argv);
}

fn ziege_mode(app: Launcher) !void {
    log.debug("We are running in goat mode.", .{});
    var argv = ArgList.init(app.allocator);
    defer argv.deinit();
    try extract_args(app, &argv);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const stat = gpa.deinit();
        if (stat == .leak) {
            std.log.err("Memory leak detected!", .{});
            std.process.exit(1);
        }
    }

    var app = try Launcher.init(gpa.allocator());
    defer app.deinit() catch @panic("Unrecoverable error during shutdown!");

    log.debug("HOME = {s}", .{app.locations.home});

    switch (app.mode) {
        .Zig => try zig_mode(app),
        .Zls => try zls_mode(app),
        .Ziege => try ziege_mode(app),
    }
}
