const std = @import("std");
const Io = std.Io;
const Paths = @import("Paths.zig");
const mojang = @import("mojang.zig");
const known_folders = @import("known-folders");
const Session = @import("Session.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();
    _ = args_it.next(); // skip argv[0]

    var requested_version: ?[]const u8 = null;
    var offline = false;
    var name: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            requested_version = args_it.next() orelse return error.MissingVersionArg;
        } else if (std.mem.eql(u8, arg, "--offline") or std.mem.eql(u8, arg, "-o")) {
            offline = true;
            name = args_it.next() orelse "Player";
        } else if (std.mem.eql(u8, arg, "--login") or std.mem.eql(u8, arg, "-l")) {
            name = args_it.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    var mc_paths = try Paths.resolve(io, gpa, init.environ_map);
    defer mc_paths.deinit(gpa);
    std.log.info("Using Minecraft directory: {s}", .{mc_paths.root});

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    std.log.info("Fetching version manifest", .{});
    const manifest = try mojang.fetchVersionManifest(init.arena.allocator(), &client);

    const target_id = requested_version orelse manifest.latest.release;
    const chosen = blk: {
        for (manifest.versions) |v| {
            if (std.mem.eql(u8, v.id, target_id)) break :blk v;
        } else return error.VersionNotFound;
    };
    std.log.info("Selected version: {s}", .{chosen.id});

    const version = try mojang.fetchVersion(init.arena.allocator(), &client, chosen.url);

    var classpath_list: ?[]const []const u8 = null;
    defer if (classpath_list) |c| gpa.free(c);

    var group: Io.Group = .init;
    const node = std.Progress.start(io, .{ .root_name = "downloading minecraft" });

    group.async(io, ensureClient, .{ io, node, &client, &mc_paths, chosen.id, version });
    group.async(io, ensureLibs, .{ io, gpa, node, &client, &mc_paths, version, &classpath_list });
    group.async(io, ensureAssets, .{ io, gpa, node, &client, &mc_paths, version });
    const cache_path = (try known_folders.getPath(io, gpa, init.environ_map, .cache)).?;
    defer gpa.free(cache_path);
    var token_buf: [4096]u8 = undefined;
    const session: Session =
        if (offline) try .offline(gpa, name orelse "Player") else blk: {
            const store = try Session.Store.open(io, cache_path);
            if (name) |n| {
                var it = try store.list();
                while (try it.next(io)) |acc| {
                    if (std.ascii.eqlIgnoreCase(acc.name, n)) {
                        const session = try Session.online(io, gpa, &client, try store.read(io, acc.name, &token_buf));
                        errdefer session.deinit(gpa);
                        try store.write(io, acc.name, session.refresh_token.?);
                        break :blk session;
                    }
                } else {
                    std.log.warn("Account '{s}' not found. Authenticating.", .{n});
                    const session = try Session.online(io, gpa, &client, null);
                    errdefer session.deinit(gpa);
                    try store.write(io, n, session.refresh_token.?);
                    break :blk session;
                }
            } else {
                var last_name_buf: [128]u8 = undefined;
                if (try store.last(io, &last_name_buf)) |last| {
                    const session = try Session.online(io, gpa, &client, try store.read(io, last, &token_buf));
                    errdefer session.deinit(gpa);
                    try store.write(io, last, session.refresh_token.?);
                    break :blk session;
                } else {
                    std.log.warn("No last used account present. Authenticating.", .{});
                    const session = try Session.online(io, gpa, &client, null);
                    errdefer session.deinit(gpa);
                    try store.write(io, session.username, session.refresh_token.?);
                    break :blk session;
                }
            }
            try store.save(io, mc_paths.root);
        };
    defer session.deinit(gpa);
    const features: mojang.Features = .{};

    try group.await(io);
    node.end();

    try mojang.launch(
        io,
        gpa,
        &mc_paths,
        chosen.id,
        classpath_list orelse return,
        version.assetIndex.id,
        version,
        session,
        features,
    );
}
pub fn ensureClient(
    io: Io,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version_id: []const u8,
    version: mojang.Package,
) void {
    const client_node = node.start("downloading client", 0);
    mojang.ensureClient(io, node, client, paths, version_id, version) catch |err| {
        std.log.err("error while downloading client: {t}", .{err});
    };
    client_node.end();
}

fn ensureLibs(
    io: Io,
    gpa: std.mem.Allocator,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version: mojang.Package,
    out_class_paths: *?[]const []const u8,
) void {
    out_class_paths.* = mojang.ensureLibraries(io, gpa, node, client, paths, version) catch |err| {
        std.log.err("got error whilest downloading libraries: {t}", .{err});
        return;
    };
}

pub fn ensureAssets(
    io: Io,
    gpa: std.mem.Allocator,
    node: std.Progress.Node,
    client: *std.http.Client,
    paths: *Paths,
    version: mojang.Package,
) void {
    mojang.ensureAssets(io, gpa, node, client, paths, version) catch |err| {
        std.log.err("got error whilest downloading assets: {t}", .{err});
        return;
    };
}

fn printHelp() void {
    std.debug.print(
        \\zmc -- a minimal Minecraft launcher written in Zig
        \\
        \\Fetches the version manifest, client jar, libraries/natives, and
        \\assets from Mojang's public endpoints into the standard .minecraft
        \\directory, then launches the game with java.
        \\
        \\Usage:
        \\  zmc [--version <id>] [--offline [name] | --auth]
        \\
        \\  -v --version <id>    Specific version id (default: latest release)
        \\  -o --offline [name]  Launch offline/singleplayer as <name> (default: "Player")
        \\  -l --login   [name]  Sign in with a Microsoft account for online play (default: last selected)
        \\
    , .{});
}
