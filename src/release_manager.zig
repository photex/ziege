//-----------------------------------------------------------------------------
// Copyright (c) 2024 - Chip Collier, All Rights Reserved.
//-----------------------------------------------------------------------------

const builtin = @import("builtin");
const std = @import("std");
const path = std.fs.path;
const hash = std.hash;
const json = std.json;
const http = std.http;
const xz = std.compress.xz;
const tar = std.tar;
const zip = std.zip;

const File = std.fs.File;
const Dir = std.fs.Dir;
const LinearFifo = std.fifo.LinearFifo;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const globals = @import("./globals.zig");
const utils = @import("./utils.zig");
const Configuration = @import("./settings.zig").Configuration;

const log = globals.log;

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

/// For the specified package root, load the cached `index.json` and parse it.
fn loadIndexJson(allocator: Allocator, pkg_root: *Dir) !json.Parsed(json.Value) {
    var file = try pkg_root.openFile(globals.INDEX_FILENAME, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024 * 4);
    return try json.parseFromSlice(std.json.Value, allocator, contents, .{});
}

/// Get the modification time of a package root's `index.json`
fn indexModTime(pkg_root: *Dir) !i128 {
    const stat = pkg_root.statFile(globals.INDEX_FILENAME) catch |err| {
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

    const cache_file = try pkg_root.createFile(globals.INDEX_FILENAME, .{});
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

/// Holds parsed release indexes for Zig and Zls.
/// Provides several helpful functions to assist in information extraction.
/// Downloads and unpacks zig releases
pub const ReleaseManager = struct {
    const Self = @This();

    config: *const Configuration,

    wget: Wget,

    zig_index: json.Parsed(json.Value),
    zls_index: json.Parsed(json.Value),

    pub fn init(config: *const Configuration) !Self {
        const now = std.time.nanoTimestamp();

        var wget = try Wget.init(config.allocator);

        var zig_pkg_dir = try std.fs.openDirAbsolute(config.locations.zig_pkgs, .{});
        defer zig_pkg_dir.close();

        var zls_pkg_dir = try std.fs.openDirAbsolute(config.locations.zls_pkgs, .{});
        defer zls_pkg_dir.close();

        const zig_index_mtime = try indexModTime(&zig_pkg_dir);
        const zls_index_mtime = try indexModTime(&zls_pkg_dir);

        // If the mtime of our index cache is greater than 24 hours ago, we download the index before loading it.
        const zig_mod_duration = now - zig_index_mtime;
        if (zig_mod_duration > std.time.ns_per_day) {
            log.debug("Downloading {s}", .{globals.DEFAULT_ZIG_INDEX_URL});
            try downloadReleaseIndex(globals.DEFAULT_ZIG_INDEX_URL, &zig_pkg_dir, &wget);
        }

        const zls_mod_duration = now - zls_index_mtime;
        if (zls_mod_duration > std.time.ns_per_day) {
            log.debug("Downloading {s}", .{globals.DEFAULT_ZLS_INDEX_URL});
            try downloadReleaseIndex(globals.DEFAULT_ZLS_INDEX_URL, &zls_pkg_dir, &wget);
        }

        const zig_index = try loadIndexJson(config.allocator, &zig_pkg_dir);
        const zls_index = try loadIndexJson(config.allocator, &zls_pkg_dir);

        return Self{
            .config = config,
            .wget = wget,
            .zig_index = zig_index,
            .zls_index = zls_index,
        };
    }

    pub fn deinit(self: *Self) void {
        self.zls_index.deinit();
        self.zig_index.deinit();
        self.wget.deinit();
        self.* = undefined;
    }

    /// Return a pointer to the current 'master' version for the loaded zig release index.
    pub fn getZigNightlyVersion(self: *const Self) ![]const u8 {
        const master = self.zig_index.value.object.getEntry("master").?;
        return master.value_ptr.object.getEntry("version").?.value_ptr.string;
    }

    /// Return a url where the nightly release can be downloaded
    fn getNightlyZigReleaseUrl(self: *const Self, version: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.config.allocator, globals.ZIG_NIGHTLY_URL_FMT, .{ globals.URL_PLATFORM, version, globals.ARCHIVE_EXT });
    }

    fn getNightlyZlsReleaseUrl(self: *const Self) ![]u8 {
        const version = self.zls_index.value.object.getPtr("latest").?.string;
        return try std.fmt.allocPrint(self.config.allocator, globals.ZLS_NIGHTLY_URL_FMT, .{ version, globals.JSON_PLATFORM, globals.ZLS_BIN_NAME });
    }

    /// When you pin to nightly, you will end up with a version that isn't present in the index perpetually.
    /// This function just lets us know whether we can use the index or not.
    pub fn containsZigRelease(self: *const Self, version: []const u8) bool {
        return self.zig_index.value.object.contains(version);
    }

    /// Get the extended release information for a pinned Zig version.
    fn getZigReleaseInfo(self: *const Self, version: []const u8) !ZigReleaseInfo {
        const version_object = self.zig_index.value.object.getPtr(version).?;
        const info_object = version_object.object.getPtr(globals.JSON_PLATFORM).?;
        return ZigReleaseInfo{
            .tarball = info_object.object.getPtr("tarball").?.string,
            .shasum = info_object.object.getPtr("shasum").?.string,
            .size = try std.fmt.parseInt(u64, info_object.object.getPtr("size").?.string, 10),
        };
    }

    fn downloadTo(self: *Self, url: []const u8, dest_path: []const u8) !void {
        const stdout = std.io.getStdOut().writer();
        const dest_file = try std.fs.createFileAbsolute(dest_path, .{});
        defer dest_file.close();

        const uri = try std.Uri.parse(url);

        try stdout.print("Downloading {s}\n", .{url});
        try self.wget.toFile(uri, dest_file);
    }

    fn unpackZig(self: *Self, root_path: []const u8, archive_path: []const u8) !void {
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

            try utils.ensureDirectoryExists(root_path);
            errdefer std.fs.deleteDirAbsolute(root_path) catch @panic("Unable to remove zig root path after an error.");

            var root_dir = try std.fs.openDirAbsolute(root_path, .{});
            defer root_dir.close();

            var decompressor = try xz.decompress(self.config.allocator, compressed_archive.reader());
            try tar.pipeToFileSystem(root_dir, decompressor.reader(), .{ .strip_components = 1 });
        }
    }

    fn isNightlyZigVersion(self: *Self, version: []const u8) bool {
        const crc = std.hash.Crc32.hash;
        switch (crc(version)) {
            crc("master"), crc("nightly") => return true,
            else => return !self.containsZigRelease(version),
        }
    }

    pub fn installZigVersion(self: *Self, version: []const u8) !void {
        const archive_filename = try std.fmt.allocPrint(self.config.allocator, globals.ZIG_ARCHIVE_FMT, .{ globals.URL_PLATFORM, version, globals.ARCHIVE_EXT });
        const archive_path = try std.fs.path.join(self.config.allocator, &.{ self.config.locations.zig_pkgs, archive_filename });

        const zig_root_path = try self.config.locations.getZigRootPath(version);

        const is_nightly_version = self.isNightlyZigVersion(version);

        if (is_nightly_version) {
            const nightly_url = try self.getNightlyZigReleaseUrl(version);
            try self.downloadTo(nightly_url, archive_path);
        } else {
            const release_info = try self.getZigReleaseInfo(version);
            try self.downloadTo(release_info.tarball, archive_path);
            // TODO: Tagged releases can be easily verified after download.
            //       - shasum
            //       - size
        }
        defer std.fs.deleteFileAbsolute(archive_path) catch @panic("Failed to remove downloaded archive.");

        try self.unpackZig(zig_root_path, archive_path);

        try self.installZls(zig_root_path, is_nightly_version);
    }

    fn installZls(self: *Self, zig_root_path: []const u8, nightly: bool) !void {
        //const zig_version = std.fs.path.basename(zig_root_path);
        const zls_path = try std.fs.path.join(self.config.allocator, &.{ zig_root_path, globals.ZLS_BIN_NAME });
        if (nightly) {
            const zls_url = try self.getNightlyZlsReleaseUrl();
            try self.downloadTo(zls_url, zls_path);

            const zls_bin = try std.fs.openFileAbsolute(zls_path, .{});
            defer zls_bin.close();
            if (builtin.os.tag != .windows) {
                const exec_mode = 0o755;
                try zls_bin.chmod(exec_mode);
            }
        } else {
            log.warn("Installing stable ZLS versions are not yet implemented.\n", .{});
        }
    }

    pub fn uninstallZigVersion(self: *Self, version: []const u8) !void {
        const zig_root_path = try self.config.locations.getZigRootPath(version);
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Removing: {s}\n", .{zig_root_path});
        try std.fs.deleteTreeAbsolute(zig_root_path);
    }
};
