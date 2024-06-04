//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

const builtin = @import("builtin");
const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const mem = std.mem;
const json = std.json;
const http = std.http;
const xz = std.compress.xz;
const tar = std.tar;
const zip = std.zip;

const Allocator = mem.Allocator;
const assert = std.debug.assert;

const LinearFifo = std.fifo.LinearFifo;

//-----------------------------------------------------------------------------

const INDEX_FILENAME = "index.json";
const ZIGVERSION_FILENAME = ".zigversion";

/// <URL_PLATFORM>-<VERSION>.<ARCHIVE_EXT>
const ZIG_NIGHTLY_URL_FMT = "https://ziglang.org/builds/zig-{s}-{s}.{s}";
const ZIG_ARCHIVE_FMT = "zig-{s}-{s}.{s}";

// TODO: This should be a configuration parameter so that custom/private indexes are possible.
const ZIG_INDEX_URL = "https://ziglang.org/download/index.json";
const ZIG_BIN_NAME_HASH = switch (builtin.os.tag) {
    .windows => hash.Crc32.hash("zig.exe"),
    else => hash.Crc32.hash("zig"),
};

// TODO: This should be a configuration parameter so that custom/private indexes are possible.
const ZLS_INDEX_URL = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";
const ZLS_BIN_NAME_HASH = switch (builtin.os.tag) {
    .windows => hash.Crc32.hash("zls.exe"),
    else => hash.Crc32.hash("zls"),
};

const Mode = enum { Zig, Zls, Ziege };
const Command = enum { Update, Fetch, SetDefault };

const Dir = std.fs.Dir;
const File = std.fs.File;

const ArgList = std.ArrayList([:0]u8);

const log = std.log.scoped(.ziege);

const ARCH = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    else => @compileError("Unsupported CPU Architecture"),
};

const OS = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};

const URL_PLATFORM = OS ++ "-" ++ ARCH;
const JSON_PLATFORM = ARCH ++ "-" ++ OS;
const ARCHIVE_EXT = if (builtin.os.tag == .windows) "zip" else "tar.xz";

//-----------------------------------------------------------------------------

/// For args that start with '+' we interpret as arguments
/// for ziege rather than the tool we are proxying.
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

fn ensureDirectoryExists(abs_path: []const u8) !void {
    std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

/// A simple struct with paths to our configured/standard locations on the system.
const Locations = struct {
    const Self = @This();

    allocator: Allocator,
    app_data: []u8,
    config_file: []u8,
    pkg_root: []u8,
    zig_pkgs: []u8,
    zls_pkgs: []u8,

    /// Build our paths to standard locations, and creates any missing directories if needed.
    pub fn init(allocator: Allocator) !Self {
        const app_data = try std.fs.getAppDataDir(allocator, "ziege");
        const config_file = try std.fs.path.join(allocator, &.{ app_data, "settings.json" });
        const pkg_root = try std.fs.path.join(allocator, &.{ app_data, "pkg" });
        const zig_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zig" });
        const zls_pkgs = try std.fs.path.join(allocator, &.{ pkg_root, "zls" });

        log.debug("ZIEGE ROOT: {s}", .{app_data});
        log.debug("ZIG PACKAGES: {s}", .{zig_pkgs});
        log.debug("ZLS PACKAGES: {s}", .{zls_pkgs});

        // I'm assuming here that we can "make" a dirt that already exists without errors.
        try ensureDirectoryExists(app_data);
        try ensureDirectoryExists(pkg_root);
        try ensureDirectoryExists(zig_pkgs);
        try ensureDirectoryExists(zls_pkgs);

        return Self{
            .allocator = allocator,
            .app_data = app_data,
            .config_file = config_file,
            .pkg_root = pkg_root,
            .zig_pkgs = zig_pkgs,
            .zls_pkgs = zls_pkgs,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.app_data);
        self.allocator.free(self.config_file);
        self.allocator.free(self.pkg_root);
        self.allocator.free(self.zig_pkgs);
        self.allocator.free(self.zls_pkgs);
        self.* = undefined;
    }

    pub fn getZigRootPath(self: *Self, version: []const u8) ![]u8 {
        return try std.fs.path.join(self.allocator, &.{ self.zig_pkgs, version });
    }
};

/// A simple wrapper around std.http.Client to easily facilitate file downloads.
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

    /// Download the content located at the provided Uri to the specified destination file.
    /// > Important to note that we *do not* currently verify the content type of the response.
    pub fn toFile(self: *Self, uri: std.Uri, dest: File) !void {
        var request = try self.get(uri);
        defer request.deinit();

        // TODO: We should be ensuring that downloades conform to certain expectations.
        // const json_content_type = "application/json";
        // const bin_content_type = "application/octet-stream";
        // const gz_content_type = "application/gzip";
        // const zip_content_type = "application/zip";
        // const tar_content_type = "application/x-tar";

        const reader = request.reader();
        const writer = dest.writer();

        const Pump = LinearFifo(u8, .{ .Static = 64 });
        var fifo = Pump.init();
        defer fifo.deinit();
        try fifo.pump(reader, writer);
    }

    /// Construct the basic GET request for the given Uri.
    /// > Important to note that this asserts that a response status is 'OK'!
    fn get(self: *Self, uri: std.Uri) !http.Client.Request {
        var request = try self.client.open(.GET, uri, .{
            .server_header_buffer = self.header_buf,
        });

        try request.send();
        try request.finish();
        try request.wait();

        // *TODO* This is a pretty severe step I guess. We need to more clearly handle failures.
        assert(request.response.status == .ok);

        return request;
    }
};

/// If there is a `.zigversion` file present in the current directory, we read the contents into a buffer.
fn loadZigVersion(allocator: Allocator) !?[]const u8 {
    var file = std.fs.cwd().openFile(ZIGVERSION_FILENAME, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        else => return err,
    };
    defer file.close();

    const result = try file.readToEndAlloc(allocator, 64);

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

    return try allocator.realloc(result, eos);
}

/// Write the specified version to `.zigversion` in the current working directory.
fn saveZigVersion(version: []const u8) !void {
    var file = try std.fs.cwd().createFile(ZIGVERSION_FILENAME, .{});
    defer file.close();
    _ = try file.write(version);
}

/// For the specified package root, load the cached `index.json` and parse it.
fn loadIndexJson(allocator: Allocator, pkg_root: *Dir) !json.Parsed(json.Value) {
    var file = try pkg_root.openFile(INDEX_FILENAME, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024 * 4);
    return try json.parseFromSlice(std.json.Value, allocator, contents, .{});
}

/// Get the modification time of a package root's `index.json`
fn indexModTime(pkg_root: *Dir) !i128 {
    const stat = pkg_root.statFile(INDEX_FILENAME) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
        return std.time.nanoTimestamp() - std.time.ns_per_week;
    };
    return stat.mtime;
}

/// Download/Update the specified release index cache.
fn downloadReleaseIndex(url: []const u8, pkg_root: *Dir, wget: *Wget) !void {
    const uri = try std.Uri.parse(url);

    const cache_file = try pkg_root.createFile(INDEX_FILENAME, .{});
    defer cache_file.close();

    try wget.toFile(uri, cache_file);
}

/// Pinned/Stable releases get full entries in the release index and we use this information rather than deriving our own urls.
/// We also take extra steps to verify download sizes and checksums.
const ZigReleaseInfo = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: u64,
};

/// Holds parsed release indexes for Zig and Zls. Provides several helpful functions to assist in information extraction.
const ReleaseIndexes = struct {
    const Self = @This();

    allocator: Allocator,
    zig: json.Parsed(json.Value),
    zls: json.Parsed(json.Value),

    /// Load `index.json` from the Zig and Zls package roots and return an instance of this struct.
    /// If the indexes are not present *or* they are more than 24 hours old, we download the latest indexes.
    pub fn load(locations: *Locations, wget: *Wget) !Self {
        const now = std.time.nanoTimestamp();

        var zig_pkg_dir = try std.fs.openDirAbsolute(locations.zig_pkgs, .{});
        defer zig_pkg_dir.close();

        var zls_pkg_dir = try std.fs.openDirAbsolute(locations.zls_pkgs, .{});
        defer zls_pkg_dir.close();

        const zig_index_mtime = try indexModTime(&zig_pkg_dir);
        const zls_index_mtime = try indexModTime(&zls_pkg_dir);

        // If the mtime of our index cache is greater than 24 hours ago, we download the index before loading it.
        const zig_mod_duration = now - zig_index_mtime;
        if (zig_mod_duration > std.time.ns_per_day) {
            log.debug("Downloading {s}", .{ZIG_INDEX_URL});
            try downloadReleaseIndex(ZIG_INDEX_URL, &zig_pkg_dir, wget);
        }

        const zls_mod_duration = now - zls_index_mtime;
        if (zls_mod_duration > std.time.ns_per_day) {
            log.debug("Downloading {s}", .{ZLS_INDEX_URL});
            try downloadReleaseIndex(ZLS_INDEX_URL, &zls_pkg_dir, wget);
        }

        const zig_index = try loadIndexJson(locations.allocator, &zig_pkg_dir);
        const zls_index = try loadIndexJson(locations.allocator, &zls_pkg_dir);

        return Self{
            .allocator = locations.allocator,
            .zig = zig_index,
            .zls = zls_index,
        };
    }

    /// Return a pointer to the current 'master' version for the loaded zig release index.
    fn getZigNightlyVersion(self: *const Self) ![]const u8 {
        const master = self.zig.value.object.getEntry("master").?;
        return master.value_ptr.object.getEntry("version").?.value_ptr.string;
    }

    /// Return a url where the nightly release can be downloaded
    pub fn getNightlyReleaseUrl(self: *const Self, version: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, ZIG_NIGHTLY_URL_FMT, .{ URL_PLATFORM, version, ARCHIVE_EXT });
    }

    /// When you pin to nightly, you will end up with a version that isn't present in the index perpetually.
    /// This function just lets us know whether we can use the index or not.
    pub fn containsZigRelease(self: *const Self, version: []const u8) bool {
        return self.zig.value.object.contains(version);
    }

    /// Get the extended release information for a pinned Zig version.
    pub fn getReleaseInfo(self: *const Self, version: []const u8) !ZigReleaseInfo {
        const version_object = self.zig.value.object.getPtr(version).?;
        const info_object = version_object.object.getPtr(JSON_PLATFORM).?;
        return ZigReleaseInfo{
            .tarball = info_object.object.getPtr("tarball").?.string,
            .shasum = info_object.object.getPtr("shasum").?.string,
            .size = try std.fmt.parseInt(u64, info_object.object.getPtr("size").?.string, 10),
        };
    }
};

/// Get the current nightly version from our cached release index, and update `.zigversion`.
fn pinToNightlyZig(releases: *const ReleaseIndexes) ![]const u8 {
    const version = try releases.getZigNightlyVersion();
    try saveZigVersion(version);
    return version;
}

fn dirExists(abs_path: []const u8) !bool {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    dir.close();
    return true;
}

fn fetchZig(archive_url: []const u8, archive_path: []const u8, wget: *Wget) !void {
    const stdout = std.io.getStdOut().writer();
    const archive = try std.fs.createFileAbsolute(archive_path, .{});
    defer archive.close();

    const uri = try std.Uri.parse(archive_url);

    try stdout.print("Downloading {s}\n", .{archive_url});
    try wget.toFile(uri, archive);
}

fn unpackZig(allocator: Allocator, root_path: []const u8, archive_path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Unpacking Zig release to: {s}\n", .{root_path});

    var compressed_archive = try std.fs.openFileAbsolute(archive_path, .{});
    defer compressed_archive.close();

    if (builtin.os.tag == .windows) {
        // Windows releases are provided as zip archives as this is the Windows standard archive format.
        // Unfortunately there isn't any way to strip the prefix during extraction, so what we do instead
        // is extract and rename.

        const pkgs_path = std.fs.path.dirname(root_path).?;
        const pkg_root_name = std.fs.path.basename(root_path);
        const archive_name = std.fs.path.stem(archive_path);

        var pkgs_dir = try std.fs.openDirAbsolute(pkgs_path, .{});
        defer pkgs_dir.close();

        // Extract the zip contents to the package root, which will create a directory which matches the archive stem
        const stream = compressed_archive.seekableStream();
        try zip.extract(pkgs_dir, stream, .{});

        // Rename the extracted directory to just the version
        log.debug("Renaming {s} => {s}", .{ archive_name, pkg_root_name });
        try pkgs_dir.rename(archive_name, pkg_root_name);
    } else {
        // On non-windows systems we can use tar and strip the prefix, so much easier. So we create our target
        // folder first, and extract directly into it.

        try ensureDirectoryExists(root_path);
        errdefer std.fs.deleteDirAbsolute(root_path) catch @panic("Unable to remove zig root path after an error.");

        var root_dir = try std.fs.openDirAbsolute(root_path, .{});
        defer root_dir.close();

        var decompressor = try xz.decompress(allocator, compressed_archive.reader());
        try tar.pipeToFileSystem(root_dir, decompressor.reader(), .{ .strip_components = 1 });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const bin_name = path.basename(args[0]);
    const bin_name_hash = hash.Crc32.hash(bin_name);

    const mode: Mode = switch (bin_name_hash) {
        ZIG_BIN_NAME_HASH => .Zig,
        ZLS_BIN_NAME_HASH => .Zls,
        else => .Ziege,
    };
    switch (mode) {
        .Ziege => log.debug("Running in Ziege mode.", .{}),
        .Zig => log.debug("Running in Zig mode.", .{}),
        .Zls => log.debug("Running in Zls mode.", .{}),
    }

    var wget = try Wget.init(allocator);
    defer wget.deinit();

    var locations = try Locations.init(allocator);
    defer locations.deinit();

    const releases = try ReleaseIndexes.load(&locations, &wget);

    const zig_version = try loadZigVersion(allocator) orelse try pinToNightlyZig(&releases);

    const zig_root_path = try locations.getZigRootPath(zig_version);
    log.debug("Zig root: {s}", .{zig_root_path});

    if (!try dirExists(zig_root_path)) {
        const archive_filename = try std.fmt.allocPrint(allocator, ZIG_ARCHIVE_FMT, .{ URL_PLATFORM, zig_version, ARCHIVE_EXT });
        const archive_path = try std.fs.path.join(allocator, &.{ locations.zig_pkgs, archive_filename });

        if (releases.containsZigRelease(zig_version)) {
            const release_info = try releases.getReleaseInfo(zig_version);
            try fetchZig(release_info.tarball, archive_path, &wget);
        } else {
            const nightly_url = try releases.getNightlyReleaseUrl(zig_version);
            try fetchZig(nightly_url, archive_path, &wget);
        }
        defer std.fs.deleteFileAbsolute(archive_path) catch @panic("Failed to remove downloaded archive.");

        try unpackZig(allocator, zig_root_path, archive_path);
    }
}
