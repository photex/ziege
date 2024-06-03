const builtin = @import("builtin");
const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const json = std.json;
const http = std.http;

const Allocator = mem.Allocator;
const assert = std.debug.assert;

const LinearFifo = std.fifo.LinearFifo;

const default_zig_version = "master";

const json_content_type = "application/json";
const bin_content_type = "application/octet-stream";
const gz_content_type = "application/gzip";
const zip_content_type = "application/zip";
const tar_content_type = "application/x-tar";

const zig_index_url = "https://ziglang.org/download/index.json";
const zig_bin_name_hash = hash.Crc32.hash("zig");

const zls_index_url = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";
const zls_bin_name_hash = hash.Crc32.hash("zls");

const Mode = enum { Zig, Zls, Ziege };
const Command = enum { Update, Fetch, SetDefault };

const Dir = std.fs.Dir;
const File = std.fs.File;

const ArgList = std.ArrayList([:0]u8);

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

const ZigVersion = union(enum) {
    Master,
    Stable,
    Pinned: [32]u8,
};

/// For args that start with '+' we interpret as arguments
/// for us rather than the tools we proxy.
fn extract_args(allocator: Allocator, launcher_args: *ArgList, forward_args: *ArgList) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try forward_args.ensureTotalCapacity(args.len);
    try launcher_args.ensureTotalCapacity(args.len);

    // We preserve the path to the executable that got run in the launcher
    // args so that we can figure out what mode to operate in etc.
    const binpath = try allocator.dupeZ(u8, args[0]);
    try launcher_args.append(binpath);

    for (args[1..]) |arg| {
        const copy = try allocator.dupeZ(u8, arg);
        if (arg[0] == '+') {
            try launcher_args.append(copy);
        } else {
            try forward_args.append(copy);
        }
    }
}

const Locations = struct {
    const Self = @This();

    allocator: Allocator,
    home: []u8,
    config: []u8,
    pkg_root: []u8,
    zig_pkgs: []u8,
    zls_pkgs: []u8,

    zig_index_cache: []u8,
    zls_index_cache: []u8,

    pub fn init(allocator: Allocator) !Self {
        const home = try std.process.getEnvVarOwned(allocator, home_var);
        const config = try std.fs.path.join(allocator, &.{ home, ".ziege" });
        const pkg_root = try std.fs.path.join(allocator, &.{ config, "pkg" });
        const zig_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zig" });
        const zig_index_cache = try std.fs.path.join(allocator, &.{ pkg_root, "zig", "index.json" });
        const zls_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zls" });
        const zls_index_cache = try std.fs.path.join(allocator, &.{ pkg_root, "zls", "index.json" });

        log.debug("ZIEGE ROOT: {s}", .{config});
        log.debug("ZIG PACKAGES: {s}", .{zig_pkgs});
        log.debug("ZLS PACKAGES: {s}", .{zls_pkgs});

        // TODO: This is quite a hack currently
        var home_dir = try std.fs.openDirAbsolute(home, .{});
        try home_dir.makePath(".ziege/pkg/zig");
        try home_dir.makePath(".ziege/pkg/zls");
        home_dir.close();

        return Self{
            .allocator = allocator,
            .home = home,
            .config = config,
            .pkg_root = pkg_root,
            .zig_pkgs = zig_pkgs,
            .zls_pkgs = zls_pkgs,
            .zig_index_cache = zig_index_cache,
            .zls_index_cache = zls_index_cache,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.home);
        self.allocator.free(self.config);
        self.allocator.free(self.pkg_root);
        self.allocator.free(self.zig_pkgs);
        self.allocator.free(self.zls_pkgs);
        self.allocator.free(self.zig_index_cache);
        self.allocator.free(self.zls_index_cache);
        self.allocator = undefined;
    }
};

const ZigReleaseInfo = struct {
    tarball: std.Uri,
    shasum: [64]u8,
    size: u64,
};

const Wget = struct {
    const Self = @This();

    allocator: Allocator,
    client: http.Client,
    header_buf: []u8,

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .header_buf = try allocator.alloc(u8, 1024 * 4),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.header_buf);
        self.client.deinit();
    }

    pub fn fetchJson(self: *Self, uri: std.Uri) !std.json.Parsed(std.json.Value) {
        var request = try self.get(uri);
        defer request.deinit();
        assert(std.mem.eql(u8, request.response.content_type.?, json_content_type));

        var reader = request.reader();
        const body = try reader.readAllAlloc(self.allocator, 1024 * 1024 * 4);
        defer self.allocator.free(body);

        return try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
    }

    pub fn toFile(self: *Self, uri: std.Uri, dest: File) !void {
        var request = try self.get(uri);
        defer request.deinit();

        const reader = request.reader();
        const writer = dest.writer();

        const Pump = LinearFifo(u8, .{ .Static = 64 });
        var fifo = Pump.init();
        defer fifo.deinit();
        try fifo.pump(reader, writer);
    }

    fn get(self: *Self, uri: std.Uri) !http.Client.Request {
        var request = try self.client.open(.GET, uri, .{
            .server_header_buffer = self.header_buf,
        });

        try request.send();
        try request.finish();
        try request.wait();

        assert(request.response.status == .ok);

        return request;
    }
};

const Launcher = struct {
    const Self = @This();

    allocator: Allocator,
    launcher_args: ArgList,
    forward_args: ArgList,
    mode: Mode,
    locations: Locations,

    pub fn init(allocator: Allocator) !Self {
        log.debug("Initializing...", .{});

        var launcher_args = ArgList.init(allocator);
        var forward_args = ArgList.init(allocator);

        try extract_args(allocator, &launcher_args, &forward_args);

        const bin_name = path.basename(launcher_args.items[0]);
        const bin_name_hash = hash.Crc32.hash(bin_name);

        const mode: Mode = switch (bin_name_hash) {
            zig_bin_name_hash => .Zig,
            zls_bin_name_hash => .Zls,
            else => .Ziege,
        };

        const locations = try Locations.init(allocator);

        return Self{
            .allocator = allocator,
            .launcher_args = launcher_args,
            .forward_args = forward_args,
            .mode = mode,
            .locations = locations,
        };
    }

    pub fn deinit(self: *Self) !void {
        log.debug("Cleaning up...", .{});
        self.locations.deinit();

        for (self.launcher_args.items) |arg| {
            self.allocator.free(arg);
        }
        self.launcher_args.deinit();

        for (self.forward_args.items) |arg| {
            self.allocator.free(arg);
        }
        self.forward_args.deinit();
    }

    /// Read the contents of the file specified by file_path and return a u8 slice with it's contents.
    fn readFile(self: *Self, file_path: []const u8) ![]u8 {
        var file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        return try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    }

    /// Load a zig release index
    fn loadZigReleaseIndex(self: *Self) !json.Parsed(json.Value) {
        log.warn("**TODO** toolchain index is still only read from disk at cwd.", .{});
        const index_text = try readFile(self.allocator, "zig_index.json");
        return try json.parseFromSlice(std.json.Value, self.allocator, index_text, .{});
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

fn loadZigVersion() !ZigVersion {
    var result = [_]u8{0} ** 32;
    var file = std.fs.cwd().openFile(".zigversion", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return ZigVersion.Master;
        },
        else => return err,
    };
    defer file.close();

    const bytes_read = try file.readAll(&result);
    assert(bytes_read <= result.len);

    for (0..bytes_read) |idx| {
        switch (result[idx]) {
            '\n', '\r' => result[idx] = 0,
            else => continue,
        }
    }

    return ZigVersion{ .Pinned = result };
}

fn saveZigVersion(zig_version: *ZigVersion) !void {
    var file = try std.fs.cwd().createFile(".zigversion", .{});
    defer file.close();
    switch (zig_version) {
        .Pinned => |version| file.write(version),
        else => {},
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

    const allocator = gpa.allocator();

    var wget = try Wget.init(allocator);
    defer wget.deinit();

    var locations = try Locations.init(allocator);
    defer locations.deinit();

    const zig_version = try loadZigVersion();
    log.debug("Zig version: {s}", .{zig_version.Pinned});

    // const uri = try std.Uri.parse(zig_index_url);
    // const zig_index = try wget.fetchJson(uri);
    // defer zig_index.deinit();

    // const master = zig_index.value.object.getEntry("master").?;
    // const version = master.value_ptr.object.getEntry("version").?.value_ptr;

    // std.debug.print("Current Zig master version: {s}\n", .{version.string});

    // const index_file = try std.fs.cwd().createFile(".zig_index.json", .{});
    // try wget.fetchJsonToFile(uri, index_file);
}
