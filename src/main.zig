const std = @import("std");
const Io = std.Io;
const paths_mod = @import("paths.zig");
const mojang = @import("mojang.zig");
const msa = @import("msa.zig");
const known_folders = @import("known-folders");
const SessionStore = @import("SessionStore.zig");

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

    const cache_path = try known_folders.getPath(io, gpa, init.environ_map, .cache);
    defer if (cache_path) |c| gpa.free(c);

    const store = if (cache_path) |c| try SessionStore.init(io, c) else null;
    defer if (store) |s| s.deinit(io);

    var mc_paths = try paths_mod.resolve(io, gpa, init.environ_map);
    defer mc_paths.deinit();
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

    var group: Io.Group = .init;
    const node = std.Progress.start(io, .{ .root_name = "downloading minecraft" });

    group.async(io, ensureClient, .{ io, node, &client, &mc_paths, chosen.id, version });

    const classpath_list = try mojang.ensureLibraries(io, gpa, node, &client, &mc_paths, version);
    defer gpa.free(classpath_list);

    try mojang.ensureAssets(io, gpa, node, &client, &mc_paths, version);

    var refresh_token_buf: [1024]u8 = undefined;
    var last_name_buf: [1024]u8 = undefined;

    const selected_name = name orelse if (store) |s| try s.last(io, &last_name_buf) else null;
    const refresh_token = if (selected_name) |n|
        (if (store) |s| try s.read(io, n, &refresh_token_buf) else null)
    else
        null;

    var session: mojang.Session = if (!offline)
        try msa.authenticate(io, gpa, &client, refresh_token)
    else
        try mojang.offlineSession(gpa, name.?);
    if (session.refresh_token) |r| {
        if (store) |s| try s.write(io, session.username, r);
    }
    defer session.deinit(gpa);
    const features: mojang.Features = .{};

    try group.await(io);
    node.end();

    try mojang.launch(
        io,
        gpa,
        &mc_paths,
        chosen.id,
        classpath_list,
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
    paths: *paths_mod.Paths,
    version_id: []const u8,
    version: mojang.Package,
) void {
    const client_node = node.start("downloading client", 0);
    mojang.ensureClient(io, node, client, paths, version_id, version) catch |err| {
        std.log.err("error while downloading client: {t}", .{err});
    };
    client_node.end();
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
