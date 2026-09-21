const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const known_folders = @import("known-folders");

const Paths = @This();

root: []const u8,
versions: []const u8,
libraries: []const u8,
assets: []const u8,
natives_root: []const u8,

pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
    allocator.free(self.root);
    allocator.free(self.versions);
    allocator.free(self.libraries);
    allocator.free(self.assets);
    allocator.free(self.natives_root);
}

fn defaultRoot(io: Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = (try known_folders.getPath(allocator, .roaming_configuration)) orelse
                return error.NoAppDataDir;
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &.{ appdata, ".minecraft" });
        },
        .macos => {
            const data_dir = (try known_folders.getPath(allocator, .data)) orelse
                return error.NoDataDir;
            defer allocator.free(data_dir);
            return std.fs.path.join(allocator, &.{ data_dir, "minecraft" });
        },
        else => {
            const home = (try known_folders.getPath(io, allocator, env, .home)) orelse
                return error.NoHomeDir;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".minecraft" });
        },
    }
}

pub fn resolve(io: Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Paths {
    const root = try defaultRoot(io, allocator, env);
    const versions = try std.fs.path.join(allocator, &.{ root, "versions" });
    const libraries = try std.fs.path.join(allocator, &.{ root, "libraries" });
    const assets = try std.fs.path.join(allocator, &.{ root, "assets" });
    const natives_root = try std.fs.path.join(allocator, &.{ root, "natives" });
    const cwd = Io.Dir.cwd();

    try cwd.createDirPath(io, root);
    try cwd.createDirPath(io, versions);
    try cwd.createDirPath(io, libraries);
    try cwd.createDirPath(io, assets);
    try cwd.createDirPath(io, natives_root);

    return Paths{
        .root = root,
        .versions = versions,
        .libraries = libraries,
        .assets = assets,
        .natives_root = natives_root,
    };
}
