const std = @import("std");
const Io = std.Io;
const paths_mod = @import("paths.zig");
const mojang = @import("mojang.zig");
const msa = @import("msa.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();
    _ = args_it.next(); // skip argv[0]

    var requested_version: ?[]const u8 = null;
    var offline_name: ?[]const u8 = null;
    var use_auth = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            requested_version = args_it.next() orelse return error.MissingVersionArg;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            offline_name = args_it.next() orelse "Player";
        } else if (std.mem.eql(u8, arg, "--auth")) {
            use_auth = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    if (offline_name == null and !use_auth) offline_name = "Player";

    var mc_paths = try paths_mod.resolve(io, gpa, init.environ_map);
    defer mc_paths.deinit();
    std.log.info("Using Minecraft directory: {s}", .{mc_paths.root});

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    const manifest = try mojang.fetchVersionManifest(init.arena.allocator(), &client);

    const chosen = try mojang.pickVersion(manifest, requested_version);
    std.log.info("Selected version: {s}", .{chosen.id});

    const version = try mojang.fetchVersion(init.arena.allocator(), &client, chosen.url);

    try mojang.ensureClient(io, &client, &mc_paths, chosen.id, version);

    var classpath_list = try mojang.ensureLibraries(io, gpa, &client, &mc_paths, version);
    defer classpath_list.deinit(gpa);

    try mojang.ensureAssets(io, gpa, &client, &mc_paths, version);

    var session: mojang.Session = if (use_auth)
        try msa.authenticate(io, gpa, &client)
    else
        try mojang.offlineSession(gpa, offline_name.?);
    defer session.deinit(gpa);
    const features: mojang.Features = .{};

    try mojang.launch(
        io,
        gpa,
        &mc_paths,
        chosen.id,
        classpath_list.items,
        version.assetIndex.id,
        version,
        session,
        features,
    );
}

fn printHelp() void {
    std.debug.print(
        \\zmc -- a minimal Minecraft launcher written in Zig
        \\
        \\Fetches the version manifest, client jar, libraries/natives, and
        \\assets from Mojang's public endpoints into the standard .minecraft
        \\directory (auto-detected per OS), then launches the game with java.
        \\
        \\Usage:
        \\  zmc [--version <id>] [--offline [name] | --auth]
        \\
        \\  --version <id>    Specific version id (default: latest release)
        \\  --offline [name]  Launch offline/singleplayer as <name> (default: "Player")
        \\  --auth            Sign in with a Microsoft account for online play
        \\
        \\If neither --offline nor --auth is given, --offline "Player" is used.
        \\
    , .{});
}
