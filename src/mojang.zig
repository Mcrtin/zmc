const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const http = @import("http.zig");
const Paths = @import("Paths.zig");
const Session = @import("Session.zig");
const Allocator = std.mem.Allocator;

const MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

pub fn fetchVersionManifest(arena: std.mem.Allocator, client: *std.http.Client) !Manifest {
    return http.requestJson(Manifest, arena, client, manifest_url, &.{}, null);
}

pub fn fetchVersion(arena: std.mem.Allocator, client: *std.http.Client, url: []const u8) !Package {
    return http.requestJson(Package, arena, client, try std.Uri.parse(url), &.{}, null);
}

pub fn ensureClient(
    io: Io,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version_id: []const u8,
    version: Package,
) !void {
    const download = version.downloads.client;
    const file = try http.pathsToFile(io, download.size, &.{ paths.versions, version_id, version_id }, ".jar");
    defer file.file.close(io);
    if (file.download) {
        node.increaseEstimatedTotalItems(1);
        http.download(io, client, download.url, download.sha1, file.file) catch |err| {
            std.log.err("failed to download client: {t}", .{err});
            return;
        };
        node.completeOne();
    }
}

const os_name: OsName = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .osx,
    .linux => .linux,
    else => .linux,
};

const currentArch: Arch = switch (builtin.cpu.arch) {
    .x86 => .x86,
    .x86_64 => .x64,
    else => @compileError("unsupported"),
};

pub fn ensureLibraries(
    io: Io,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version: Package,
) Io.Cancelable!void {
    const lib_node = node.start("Downloading libs", version.libraries.len);
    var group: Io.Group = .init;

    for (version.libraries) |lib| {
        const art = lib.artifact() catch |err| switch (err) {
            error.MissingArtifact => {
                std.log.warn("library {s} is missing an artifact", .{lib.name});
                lib_node.completeOne();
                continue;
            },
            error.SystemMismatch => {
                std.log.debug("skipping library {s} due to system missmatch", .{lib.name});
                lib_node.completeOne();
                continue;
            },
        };

        group.async(io, downloadLib, .{ io, client, art.url, art.sha1, lib_node, paths.libraries, art });
    }
    try group.await(io);
    lib_node.end();
}

pub fn getClasspath(alloc: Allocator, version: Package) Allocator.Error![]const []const u8 {
    var classpath: std.ArrayList([]const u8) = try .initCapacity(alloc, version.libraries.len);
    for (version.libraries) |lib|
        classpath.appendAssumeCapacity((lib.artifact() catch continue).path);
    return classpath.toOwnedSlice(alloc);
}

fn downloadLib(
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    sha1: []const u8,
    node: std.Progress.Node,
    lib_path: []const u8,
    artifact: Artifact,
) void {
    const file = http.pathsToFile(io, artifact.size, &.{ lib_path, artifact.path }, "") catch |err| {
        std.log.err("failed to open asset file: {t}", .{err});
        return;
    };

    defer file.file.close(io);
    if (file.download) {
        http.download(io, client, url, sha1, file.file) catch |err| {
            std.log.err("failed to download lib: {t}", .{err});
            return;
        };
    }

    node.completeOne();
}

pub fn ensureAssets(
    io: Io,
    gpa: std.mem.Allocator,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version: Package,
) !void {
    const asset_index = version.assetIndex;

    const files = try http.pathsToFile(io, asset_index.size, &.{ paths.assets, "indexes", asset_index.id }, ".json");
    const file = files.file;
    defer file.close(io);
    if (files.download) {
        try http.download(io, client, asset_index.url, asset_index.sha1, files.file);
    }
    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var json_reader = std.json.Reader.init(gpa, &reader.interface);
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(struct { objects: std.json.ArrayHashMap(Asset) }, gpa, &json_reader, .{});
    defer parsed.deinit();
    const asset_node = node.start("Downloading assets", parsed.value.objects.map.entries.len);

    var group: Io.Group = .init;
    for (parsed.value.objects.map.values()) |asset| {
        group.async(io, downloadAsset, .{ io, client, asset, paths.assets, asset_node });
    }
    try group.await(io);
    asset_node.end();
}

const Asset = struct { hash: [40]u8, size: u64 };

fn downloadAsset(
    io: Io,
    client: *std.http.Client,
    asset: Asset,
    asset_path: []const u8,
    node: std.Progress.Node,
) void {
    var buf: [1024]u8 = undefined;
    const file = http.pathsToFile(io, asset.size, &.{ asset_path, "objects", asset.hash[0..2], &asset.hash }, "") catch |err| {
        std.log.err("failed to open asset file: {t}", .{err});
        return;
    };
    defer file.file.close(io);
    if (file.download) {
        const url = std.fmt.bufPrint(&buf, "https://resources.download.minecraft.net/{s}/{s}", .{ asset.hash[0..2], asset.hash }) catch {
            std.log.err("failed create url; hash is too long: {s}", .{asset.hash});
            return;
        };
        http.download(io, client, url, &asset.hash, file.file) catch |err| {
            std.log.err("failed to download asset: {t}", .{err});
            return;
        };
    }
    node.completeOne();
}

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
        .version_type = version.type,
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
    try std.process.setCurrentPath(io, paths.root);
    switch (std.process.replace(io, .{ .argv = argv.items, .expand_arg0 = .expand })) {
        error.FileNotFound => std.log.err("unable to find java runtime", .{}),
        else => |e| return e,
    }
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
const Download = struct {
    sha1: []const u8,
    size: usize,
    url: []const u8,
};
const Library = struct {
    downloads: Downloads,
    name: []const u8,
    natives: struct { linux: ?[]const u8 = null, osx: ?[]const u8 = null, windows: ?[]const u8 = null } = .{},
    extract: ?struct {
        exclude: []const []const u8,
    } = null,
    rules: []const Rule = &.{},

    const Downloads = struct {
        artifact: ?Artifact = null,
        classifiers: ?std.json.ArrayHashMap(Artifact) = null,
    };

    pub fn artifact(lib: Library) error{ SystemMismatch, MissingArtifact }!Artifact {
        if (!lib.libraryAllowed()) {
            return error.SystemMismatch;
        }

        const art = if (lib.downloads.classifiers) |classifiers|
            if (switch (os_name) {
                .linux => lib.natives.linux,
                .osx => lib.natives.osx,
                .windows => lib.natives.windows,
            }) |name| classifiers.map.get(name) else {
                std.log.warn("library {s} missing rule for current system {t}.", .{ lib.name, os_name });
                return error.SystemMismatch;
            }
        else
            lib.downloads.artifact;
        return art orelse return error.MissingArtifact;
    }

    fn libraryAllowed(lib: Library) bool {
        var allowed = false;
        if (lib.rules.len == 0) return true;
        for (lib.rules) |rule| {
            const matches = if (rule.os) |os|
                (if (os.name) |name|
                    name == os_name
                else if (os.arch) |arch| arch == currentArch else true)
            else
                true;
            if (matches) allowed = rule.action == .allow;
        }
        return allowed;
    }
};

pub const Package = struct {
    arguments: ?struct {
        @"default-user-jvm": ?[]const std.json.Value = null,
        game: []const std.json.Value,
        jvm: []const std.json.Value,
    } = null,
    minecraftArguments: ?[]const u8 = null,
    assetIndex: struct { id: []const u8, sha1: []const u8, size: u32, totalSize: u32, url: []const u8 },
    assets: []const u8,
    complianceLevel: ?u8 = null,
    downloads: Downloads,
    javaVersion: ?struct { component: []const u8, majorVersion: u8 } = null,
    libraries: []Library,
    logging: ?struct {
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
    } = null,
    mainClass: []const u8,
    minimumLauncherVersion: u32,

    id: []const u8,
    type: VersionType,
    releaseTime: []const u8,
    time: []const u8,

    const Downloads = struct {
        client: Download,
        client_mappings: ?Download = null,
        server: ?Download = null,
        server_mappings: ?Download = null,
        windows_server: ?Download = null,
    };
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
        if (os.name) |name| return name == os_name;
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
    version_type: VersionType,
    asset_index_id: []const u8,
    session: Session,
    classpath: []const u8,
    classpath_sep: []const u8,
};

fn substituteAll(allocator: std.mem.Allocator, raw: [][]const u8, ctx: SubstCtx) !void {
    for (raw) |*tok| tok.* = try substitutePlaceholder(allocator, tok.*, ctx);
}

fn substitutePlaceholder(allocator: std.mem.Allocator, tok: []const u8, ctx: SubstCtx) ![]u8 {
    var buf: [4096]u8 = undefined;
    const auth_session = if (ctx.session.access_token.len == 0) "" else try std.fmt.bufPrint(&buf, "token:{s}:{s}", .{ ctx.session.access_token, ctx.session.uuid }); //TODO: uuid simple??
    const pairs: [19]struct { key: []const u8, val: []const u8 } = .{
        .{ .key = "${auth_player_name}", .val = ctx.session.username },
        .{ .key = "${auth_uuid}", .val = ctx.session.uuid },
        .{ .key = "${auth_access_token}", .val = ctx.session.access_token },
        .{ .key = "${user_type}", .val = @tagName(ctx.session.user_type) },

        // legacy
        .{ .key = "${clientid}", .val = "0" },
        .{ .key = "${auth_xuid}", .val = ctx.session.xuid },
        .{ .key = "${auth_session}", .val = auth_session },
        .{ .key = "${user_properties}", .val = "{}" },

        .{ .key = "${version_type}", .val = @tagName(ctx.version_type) },
        .{ .key = "${version_name}", .val = ctx.version_id },
        .{ .key = "${game_directory}", .val = ctx.paths.root },
        .{ .key = "${assets_root}", .val = ctx.paths.assets },
        .{ .key = "${assets_index_name}", .val = ctx.asset_index_id },
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

test "json parsing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    const manifest = try http.requestJson(Manifest, arena.allocator(), &client, manifest_url, &.{}, null);
    for (manifest.versions) |v| {
        const value = try http.requestJson(Package, arena.allocator(), &client, try std.Uri.parse(v.url), &.{}, null);
        _ = value;
    }
}
