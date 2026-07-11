const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const known_folders = @import("known-folders");

/// Resolved on-disk layout for a Minecraft installation, mirroring what the
/// official launcher uses so tools/mods that expect the standard layout
/// keep working.
pub const Paths = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    versions: []const u8,
    libraries: []const u8,
    assets: []const u8,
    natives_root: []const u8,

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.versions);
        self.allocator.free(self.libraries);
        self.allocator.free(self.assets);
        self.allocator.free(self.natives_root);
    }
};

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
        .allocator = allocator,
        .root = root,
        .versions = versions,
        .libraries = libraries,
        .assets = assets,
        .natives_root = natives_root,
    };
}
