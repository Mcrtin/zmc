const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const http = @import("http.zig");
const Paths = @import("paths.zig").Paths;

const MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

pub const Session = struct {
    username: []const u8,
    uuid: []const u8,
    access_token: []const u8,
    user_type: enum { legacy, msa },

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.uuid);
        allocator.free(self.access_token);
    }
};

/// Offline/singleplayer session. Mirrors the real game's offline UUID
/// derivation (MD5 of "OfflinePlayer:<name>", RFC4122 v3-style bit twiddle)
/// so the same name always maps to the same UUID, same as vanilla servers do.
pub fn offlineSession(allocator: std.mem.Allocator, name: []const u8) !Session {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(name);
    var digest: [16]u8 = undefined;
    md5.final(&digest);

    digest[6] = (digest[6] & 0x0F) | 0x30;
    digest[8] = (digest[8] & 0x3F) | 0x80;

    const uuid_str = try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        digest[0],  digest[1],  digest[2],  digest[3],
        digest[4],  digest[5],  digest[6],  digest[7],
        digest[8],  digest[9],  digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15],
    });

    return Session{
        .username = try allocator.dupe(u8, name),
        .uuid = uuid_str,
        .access_token = try allocator.dupe(u8, "0"),
        .user_type = .legacy,
    };
}

// ---------------------------------------------------------------------
// Version manifest / version json
// ---------------------------------------------------------------------

pub fn fetchVersionManifest(arena: std.mem.Allocator, client: *std.http.Client) !Manifest {
    return http.requestJson(Manifest, arena, client, manifest_url, &.{}, null);
}

pub const ChosenVersion = struct { id: []const u8, url: []const u8 };

pub fn pickVersion(manifest: Manifest, requested: ?[]const u8) !ChosenVersion {
    const target_id: []const u8 = requested orelse manifest.latest.release;
    for (manifest.versions) |v| {
        if (std.mem.eql(u8, v.id, target_id)) {
            return .{ .id = v.id, .url = v.url };
        }
    }
    return error.VersionNotFound;
}

pub fn fetchVersion(arena: std.mem.Allocator, client: *std.http.Client, url: []const u8) !Package {
    return http.requestJson(Package, arena, client, try std.Uri.parse(url), &.{}, null);
}

// ---------------------------------------------------------------------
// Client jar
// ---------------------------------------------------------------------

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn ensureClient(
    io: Io,
    client: *std.http.Client,
    paths: *Paths,
    version_id: []const u8,
    version: Package,
) !void {
    // TODO: wrong path?!
    const versions_dir = try Io.Dir.cwd().createDirPathOpen(io, paths.versions, .{});
    defer versions_dir.close(io);
    const jar_dir = try versions_dir.createDirPathOpen(io, version_id, .{});
    defer jar_dir.close(io);
    var fmt_buf: [Io.Dir.max_name_bytes]u8 = undefined;
    const jar_path = try std.fmt.bufPrint(&fmt_buf, "{s}.jar", .{version_id});
    const file = jar_dir.createFile(io, jar_path, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => |e| return e,
    };
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    std.log.info("Downloading client jar for {s}...", .{version_id});
    try http.downloadToFile(client, version.downloads.client.url, version.downloads.client.sha1, &writer.interface);
    try writer.flush();
}

// ---------------------------------------------------------------------
// Libraries + natives
// ---------------------------------------------------------------------

const currentOsName: OsName = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .osx,
    .linux => .linux,
    else => .linux,
};
const currentArch: Arch = if (builtin.cpu.arch.isX86())
    .x86
else
    .x64;

fn libraryAllowed(lib: Library) bool {
    var allowed = false;
    if (lib.rules.len == 0) return true;
    for (lib.rules) |rule| {
        const matches = if (rule.os) |os|
            (if (os.name) |name|
                name == currentOsName
            else if (os.arch) |arch| arch == currentArch else true)
        else
            true;
        if (matches) allowed = rule.action == .allow;
    }
    return allowed;
}

fn resolveArchPlaceholder(buf: []u8, raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "${arch}")) |idx| {
        const before = raw[0..idx];
        const after = raw[idx + "${arch}".len ..];
        return std.fmt.bufPrint(buf, "{s}64{s}", .{ before, after }) catch raw;
    }
    return raw;
}

pub fn ensureLibraries(
    io: Io,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    paths: *Paths,
    version: Package,
) !std.ArrayList([]const u8) {
    var classpath: std.ArrayList([]const u8) = .empty;

    for (version.libraries) |lib| {
        if (!libraryAllowed(lib)) continue;

        const artifact = if (lib.downloads.classifiers) |classifiers|
            switch (currentOsName) {
                .linux => classifiers.@"native-linux",
                .osx => classifiers.@"native-macos",
                .windows => classifiers.@"native-windows",
            }
        else
            lib.downloads.artifact;
        const libs_dir = try Io.Dir.cwd().createDirPathOpen(io, paths.libraries, .{});
        defer libs_dir.close(io);

        if (artifact) |art| {
            const file_dir = if (Io.Dir.path.dirname(art.path)) |parent| try libs_dir.createDirPathOpen(io, parent, .{}) else null;
            defer if (file_dir) |d| d.close(io);

            const file: ?Io.File = (file_dir orelse libs_dir).createFile(io, Io.Dir.path.basename(art.path), .{ .read = true, .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => null,
                else => |e| return e,
            };
            defer if (file) |f| f.close(io);
            if (file) |f| {
                var buf: [1024]u8 = undefined;
                var writer = f.writer(io, &buf);
                std.log.info("Downloading library: {s}", .{lib.name});
                try http.downloadToFile(client, art.url, art.sha1, &writer.interface);
                try writer.flush();
            }

            const looks_like_natives_for_us = std.mem.containsAtLeast(u8, lib.name, 1, ":natives-") and
                std.mem.containsAtLeast(u8, lib.name, 1, @tagName(currentOsName));
            if (looks_like_natives_for_us or lib.downloads.classifiers != null) {
                if (file) |f| {
                    const dir = try Io.Dir.cwd().createDirPathOpen(io, paths.natives_root, .{});
                    defer dir.close(io);
                    const java_dir = try dir.createDirPathOpen(io, "java", .{});
                    defer java_dir.close(io);
                    var buf: [1024]u8 = undefined;
                    var reader = f.reader(io, &buf);
                    var iter = try std.zip.Iterator.init(&reader);
                    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
                    while (try iter.next()) |item| {
                        try reader.seekTo(item.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
                        const filename = filename_buf[0..item.filename_len];
                        try reader.interface.readSliceAll(filename);
                        if (!std.mem.startsWith(u8, filename, "META-INF"))
                            try item.extract(&reader, .{}, &filename_buf, java_dir);
                    }
                }
            } else {
                try classpath.append(allocator, art.path);
            }
        }
    }

    return classpath;
}

// ---------------------------------------------------------------------
// Assets
// ---------------------------------------------------------------------

pub fn ensureAssets(
    io: Io,
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    paths: *Paths,
    version: Package,
) !void {
    const asset_index = version.assetIndex;

    const indexes_dir = try std.fs.path.join(gpa, &.{ paths.assets, "indexes" });
    defer gpa.free(indexes_dir);

    const index_dir = try Io.Dir.cwd().createDirPathOpen(io, indexes_dir, .{});
    defer index_dir.close(io);
    const index_file_name = try std.fmt.allocPrint(gpa, "{s}.json", .{asset_index.id});
    defer gpa.free(index_file_name);
    const file = index_dir.createFile(io, index_file_name, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => |e| return e,
    };
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    std.log.info("Downloading asset index: {s}", .{asset_index.id});
    try http.downloadToFile(client, asset_index.url, asset_index.sha1, &writer.interface);
    try writer.flush();

    var reader = file.reader(io, &buf);
    var json_reader = std.json.Reader.init(gpa, &reader.interface);
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(struct { objects: std.json.ArrayHashMap(struct { hash: []const u8, size: u32 }) }, gpa, &json_reader, .{});
    defer parsed.deinit();

    const objects = parsed.value.objects.map;

    const objects_dir = try std.fs.path.join(gpa, &.{ paths.assets, "objects" });
    defer gpa.free(objects_dir);
    const object_dir = try Io.Dir.cwd().createDirPathOpen(io, objects_dir, .{});
    defer object_dir.close(io);

    var it = objects.iterator();
    var count: usize = 0;
    while (it.next()) |entry| {
        const hash = entry.value_ptr.hash;
        const sub_dir = try object_dir.createDirPathOpen(io, hash[0..2], .{});
        defer sub_dir.close(io);

        const object_file = sub_dir.createFile(io, hash, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        defer object_file.close(io);
        var writer_buf: [1024]u8 = undefined;
        var object_writer = object_file.writer(io, &writer_buf);
        const url = try std.fmt.allocPrint(gpa, "https://resources.download.minecraft.net/{s}/{s}", .{ hash[0..2], hash });
        defer gpa.free(url);
        try http.downloadToFile(client, url, hash, &object_writer.interface);
        try object_writer.flush();

        count += 1;
        if (count % 200 == 0) std.log.info("Downloaded {d} assets so far...", .{count});
    }
}

// ---------------------------------------------------------------------
// Launch
// ---------------------------------------------------------------------

pub fn launch(
    io: Io,
    gpa: std.mem.Allocator,
    paths: *Paths,
    version_id: []const u8,
    libs_classpath: []const []const u8,
    asset_index_id: []const u8,
    version: Package,
    session: Session,
    features: Features,
) !void {
    const sep = if (builtin.os.tag == .windows) ";" else ":";

    var cp: std.ArrayList(u8) = .empty;
    defer cp.deinit(gpa);
    for (libs_classpath) |lib| {
        const lib_path = try std.fs.path.join(gpa, &.{ paths.libraries, lib });
        defer gpa.free(lib_path);
        try cp.appendSlice(gpa, lib_path);
        try cp.appendSlice(gpa, sep);
    }
    const jar_path = std.fs.path.fmtJoin(&.{ paths.versions, version_id, version_id });
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    try cp.appendSlice(gpa, try std.fmt.bufPrint(&path_buf, "{f}.jar", .{jar_path}));

    const ctx = SubstCtx{
        .paths = paths,
        .version_id = version_id,
        .asset_index_id = asset_index_id,
        .session = session,
        .classpath = cp.items,
        .classpath_sep = sep,
    };
    const jvm_args = try buildJvmArgs(gpa, version, features, ctx);
    defer {
        for (jvm_args) |a| gpa.free(a);
        gpa.free(jvm_args);
    }
    const game_args = try buildGameArgs(gpa, version, features, ctx);
    defer {
        for (game_args) |arg| gpa.free(arg);
        gpa.free(game_args);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, "java");
    try argv.appendSlice(gpa, jvm_args);
    try argv.append(gpa, version.mainClass);
    try argv.appendSlice(gpa, game_args);

    std.log.info("Launching Minecraft {s} as {s} with command (accessToken has been redacted):\n{f}", .{ version_id, session.username, std.fmt.Alt([]const []const u8, formatJoin){ .data = argv.items } });
    return std.process.replace(io, .{ .argv = argv.items, .expand_arg0 = .expand });
}

pub const Features = struct {
    is_quick_play_realms: bool = false,
    is_quick_play_multiplayer: bool = false,
    is_quick_play_singleplayer: bool = false,
    has_quick_plays_support: bool = false,
    has_custom_resolution: bool = false,
    is_demo_user: bool = false,
};

const Rule = struct {
    action: enum { allow, disallow },
    os: ?struct {
        name: ?OsName = null,
        arch: ?Arch = null,
        version: ?[]const u8 = null,
        versionRange: ?struct { max: ?[]const u8 = null, min: ?[]const u8 = null } = null,
    } = null,
    features: ?struct {
        is_quick_play_realms: ?bool = null,
        is_quick_play_multiplayer: ?bool = null,
        is_quick_play_singleplayer: ?bool = null,
        has_quick_plays_support: ?bool = null,
        has_custom_resolution: ?bool = null,
        is_demo_user: ?bool = null,
    } = null,
};

const VersionType = enum { snapshot, release, old_alpha, old_beta };
const VersionData = struct { id: []const u8, type: VersionType, url: []const u8, time: []const u8, releaseTime: []const u8 };
const OsName = enum { osx, windows, linux };
const Arch = enum { x86, x64 };
const Artifact = struct {
    path: []const u8,
    sha1: []const u8,
    size: usize,
    url: []const u8,
};
const Library = struct {
    downloads: struct {
        artifact: Artifact,
        classifiers: ?struct {
            @"native-linux": ?Artifact = null,
            @"native-macos": ?Artifact = null,
            @"native-windows": ?Artifact = null,
        } = null,
    },
    name: []const u8,
    natives: ?struct { linux: enum { @"native-linux" } = .@"native-linux", osx: enum { @"native-macos" } = .@"native-macos", windows: enum { @"native-windows" } = .@"native-windows" } = null,
    extract: ?struct {
        exclude: []const []const u8,
        name: []const u8,
    } = null,
    rules: []const Rule = &.{},
};
const Package = struct {
    arguments: ?struct {
        @"default-user-jvm": ?[]const std.json.Value = null,
        game: []const std.json.Value,
        jvm: []const std.json.Value,
    } = null,
    minecraftArguments: ?[]const u8 = null,
    assetIndex: struct { id: []const u8, sha1: []const u8, size: usize, totalSize: usize, url: []const u8 },
    assets: usize,
    complianceLevel: u8,
    downloads: struct {
        client: struct { sha1: []const u8, size: usize, url: []const u8 },
        server: struct { sha1: []const u8, size: usize, url: []const u8 },
    },
    javaVersion: struct { component: []const u8, majorVersion: u8 },
    libraries: []Library,
    logging: struct {
        client: struct {
            argument: []const u8,
            file: struct {
                id: []const u8,
                sha1: []const u8,
                size: usize,
                url: []const u8,
            },
            type: []const u8,
        },
    },
    mainClass: []const u8,
    minimumLauncherVersion: u32,

    id: []const u8,
    type: VersionType,
    releaseTime: []const u8,
    time: []const u8,
};
const Manifest = struct {
    latest: struct { release: []const u8, snapshot: []const u8 },
    versions: []VersionData,
};
const manifest_url = std.Uri.parse("https://launchermeta.mojang.com/mc/game/version_manifest.json") catch unreachable;

fn formatJoin(slice: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (slice.len == 0) return;
    try w.writeAll(slice[0]);
    var it = std.mem.window([]const u8, slice, 2, 1);
    while (it.next()) |window| {
        try w.writeAll(" ");
        if (std.mem.eql(u8, window[0], "--accessToken"))
            try w.writeAll("0")
        else
            try w.writeAll(window[1]);
    }
}

fn ruleMatches(rule: Rule, features: Features) bool {
    if (rule.os) |os| {
        if (os.name) |name| return name == currentOsName;
        if (os.arch) |arch| return arch == currentArch;
    }
    if (rule.features) |feature| {
        if (feature.has_custom_resolution) |f| return f == features.has_custom_resolution;
        if (feature.has_quick_plays_support) |f| return f == features.has_quick_plays_support;
        if (feature.is_demo_user) |f| return f == features.is_demo_user;
        if (feature.is_quick_play_multiplayer) |f| return f == features.is_quick_play_multiplayer;
        if (feature.is_quick_play_realms) |f| return f == features.is_quick_play_realms;
        if (feature.is_quick_play_singleplayer) |f| return f == features.is_quick_play_singleplayer;
    }
    return true;
}
fn rulesAllow(rules: []const Rule, features: Features) bool {
    var allowed = false;
    for (rules) |rule| {
        if (ruleMatches(rule, features))
            allowed = rule.action == .allow;
    }
    return allowed;
}

fn collectArgTokens(allocator: std.mem.Allocator, args_array: []const std.json.Value, features: Features) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(allocator);

    for (args_array) |item| {
        switch (item) {
            .string => |s| {
                try tokens.append(allocator, s);
            },
            .object => {
                const val = try std.json.parseFromValue(struct { rules: ?[]const Rule = null, value: std.json.Value }, allocator, item, .{ .ignore_unknown_fields = false });
                defer val.deinit();
                if (val.value.rules) |rules| if (!rulesAllow(rules, features)) continue;
                switch (val.value.value) {
                    .string => |s| try tokens.append(allocator, s),
                    .array => |a| for (a.items) |i| try tokens.append(allocator, i.string),
                    else => return error.WrongJsonTag,
                }
            },
            else => return error.WrongJsonTag,
        }
    }

    return tokens.toOwnedSlice(allocator);
}

fn buildGameArgs(allocator: std.mem.Allocator, version: Package, features: Features, ctx: SubstCtx) ![][]const u8 {
    const raw = if (version.arguments) |args_val|
        try collectArgTokens(allocator, args_val.game, features)
    else if (version.minecraftArguments) |legacy_val| blk: {
        var it = std.mem.tokenizeScalar(u8, legacy_val, ' ');
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);
        while (it.next()) |tok| try list.append(allocator, tok);
        break :blk try list.toOwnedSlice(allocator);
    } else return error.MissingGameArgs;
    errdefer allocator.free(raw);
    try substituteAll(allocator, raw, ctx);
    return raw;
}

fn buildJvmArgs(allocator: std.mem.Allocator, version: Package, features: Features, ctx: SubstCtx) ![][]const u8 {
    if (version.arguments) |args| {
        var list: std.ArrayList([]const u8) = if (args.@"default-user-jvm") |default_args|
            .initBuffer(try collectArgTokens(allocator, default_args, features))
        else
            .empty;
        errdefer list.deinit(allocator);
        const tokens = try collectArgTokens(allocator, args.jvm, features);
        defer allocator.free(tokens);
        try list.appendSlice(allocator, tokens);
        try substituteAll(allocator, list.items, ctx);
        return try list.toOwnedSlice(allocator);
    }

    var out = try allocator.alloc([]const u8, 3);
    out[0] = try std.fmt.allocPrint(allocator, "-Djava.library.path={s}", .{ctx.paths.natives_root});
    out[1] = try allocator.dupe(u8, "-cp");
    out[2] = try allocator.dupe(u8, ctx.classpath);
    return out;
}

const SubstCtx = struct {
    paths: *Paths,
    version_id: []const u8,
    asset_index_id: []const u8,
    session: Session,
    classpath: []const u8,
    classpath_sep: []const u8,
};

fn substituteAll(allocator: std.mem.Allocator, raw: [][]const u8, ctx: SubstCtx) !void {
    for (raw) |*tok| tok.* = try substitutePlaceholder(allocator, tok.*, ctx);
}

fn substitutePlaceholder(allocator: std.mem.Allocator, tok: []const u8, ctx: SubstCtx) ![]u8 {
    const Pair = struct { key: []const u8, val: []const u8 };
    const pairs = [_]Pair{
        .{ .key = "${auth_player_name}", .val = ctx.session.username },
        .{ .key = "${version_name}", .val = ctx.version_id },
        .{ .key = "${game_directory}", .val = ctx.paths.root },
        .{ .key = "${assets_root}", .val = ctx.paths.assets },
        .{ .key = "${assets_index_name}", .val = ctx.asset_index_id },
        .{ .key = "${auth_uuid}", .val = ctx.session.uuid },
        .{ .key = "${auth_access_token}", .val = ctx.session.access_token },
        .{ .key = "${user_type}", .val = @tagName(ctx.session.user_type) },
        .{ .key = "${version_type}", .val = "release" },
        .{ .key = "${clientid}", .val = "0" },
        .{ .key = "${auth_xuid}", .val = "0" },
        // jvm-args-only placeholders:
        .{ .key = "${natives_directory}", .val = ctx.paths.natives_root },
        .{ .key = "${library_directory}", .val = ctx.paths.libraries },
        .{ .key = "${classpath}", .val = ctx.classpath },
        .{ .key = "${classpath_separator}", .val = ctx.classpath_sep },
        .{ .key = "${launcher_name}", .val = "zmc" },
        .{ .key = "${launcher_version}", .val = "0.1.0" },
    };

    var result = try allocator.dupe(u8, tok);
    for (pairs) |p| {
        if (std.mem.indexOf(u8, result, p.key) != null) {
            const replaced = try std.mem.replaceOwned(u8, allocator, result, p.key, p.val);
            allocator.free(result);
            result = replaced;
        }
    }
    return result;
}
