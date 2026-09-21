const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const mojang = @import("mojang.zig");
const Allocator = std.mem.Allocator;
const known_folders = @import("known-folders");

username: []const u8,
uuid: []const u8,
xuid: []const u8,
access_token: []const u8,
/// populated iff user_type == .msa
refresh_token: ?[]const u8,
user_type: enum { legacy, msa },

const Session = @This();

pub fn deinit(self: Session, allocator: Allocator) void {
    allocator.free(self.username);
    allocator.free(self.uuid);
    allocator.free(self.xuid);
    allocator.free(self.access_token);
    if (self.refresh_token) |t| allocator.free(t);
}

pub fn online(io: Io, gpa: Allocator, client: *std.http.Client, refresh_token: ?[]const u8) !Session {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ms_token = try msAuth(io, alloc, client, refresh_token);

    std.log.info("Authenticating against xbox", .{});
    const xbl_token = try xboxAuth(alloc, client, ms_token);

    std.log.info("Authorizing against xsts", .{});
    const xsts_token = try xstsAuth(alloc, client, xbl_token);

    std.log.info("Logging in...", .{});
    const account = try login(alloc, client, xsts_token);

    std.log.info("Querring profile...", .{});
    const profile = try getProfile(alloc, client, account);

    std.log.info("Finished microsoft authorization!", .{});
    return .{
        .username = try gpa.dupe(u8, profile.name),
        .uuid = try gpa.dupe(u8, profile.id),
        .access_token = try gpa.dupe(u8, account.access_token),
        .refresh_token = try gpa.dupe(u8, ms_token.refresh_token.?),
        .xuid = try gpa.dupe(u8, "0"),
        .user_type = .msa,
    };
}

pub fn offline(allocator: Allocator, name: []const u8) !Session {
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
        .xuid = try allocator.dupe(u8, "0"),
        .user_type = .legacy,
        .refresh_token = null,
    };
}

const json_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Accept", .value = "application/json" },
};

const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32, // seconds
    expires_in: u32, // seconds
    message: []const u8,
};

const MsToken = struct {
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    token_type: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    expires_in: ?u32 = null,
    ext_expires_in: ?u32 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
    error_codes: ?[]const u32 = null,
    timestamp: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    correlation_id: ?[]const u8 = null,
    error_uri: ?[]const u8 = null,
};

const XblToken = struct {
    Token: []const u8,
    NotAfter: []const u8,
    DisplayClaims: struct {
        xui: []const struct {
            uhs: []const u8,
        },
    },
    IssueInstant: []const u8,
};

const XstsToken = struct {
    Token: []const u8,
    DisplayClaims: struct {
        xui: []const struct {
            uhs: []const u8,
        },
    },
    NotAfter: []const u8,
    IssueInstant: []const u8,
};
const Account = struct {
    username: []const u8,
    access_token: []const u8,
    expires_in: u32,
    roles: []const std.json.Value,
    token_type: []const u8,
    metadata: std.json.ArrayHashMap(std.json.Value),
};

const Profile = struct {
    id: []const u8,
    name: []const u8,
    skins: []const struct {
        id: []const u8,
        state: []const u8,
        url: []const u8,
        textureKey: []const u8,
        variant: []const u8,
    },
    capes: []const struct {
        id: []const u8,
        state: []const u8,
        url: []const u8,
        alias: []const u8,
    },
    profileActions: std.json.ArrayHashMap(std.json.Value),
};

fn msAuth(io: Io, alloc: Allocator, client: *std.http.Client, refresh_token: ?[]const u8) !MsToken {
    var buf: [8192]u8 = undefined;
    const token_url = std.Uri.parse("https://login.microsoftonline.com/consumers/oauth2/v2.0/token") catch unreachable;

    const client_id = "708e91b5-99f8-4a1d-80ec-e746cbb24771";
    const scope = "XboxLive.signin offline_access";
    const form_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    if (refresh_token) |t| {
        const body = try std.fmt.bufPrint(
            &buf,
            "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope={s}",
            .{ client_id, t, scope },
        );
        std.log.info("Refreshing authentication", .{});
        const ms_token = try requestJson(MsToken, alloc, client, token_url, &form_headers, body);
        if (ms_token.access_token != null) return ms_token;
        std.log.warn("Refresh failed, trying to reauthenticate", .{});
    }
    std.log.info("Requesting authentication code", .{});
    const device_body = "client_id=" ++ client_id ++ "&scope=" ++ scope;
    const device_code_url = std.Uri.parse("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode") catch unreachable;
    const device = try requestJson(DeviceCodeResponse, alloc, client, device_code_url, &form_headers, device_body);

    std.log.info("Opening {s}. enter code: {s}", .{ device.verification_uri, device.user_code });
    openUrl(io, alloc, device.verification_uri) catch {};

    const ms_body = try std.fmt.bufPrint(
        &buf,
        "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id={s}&device_code={s}",
        .{ client_id, device.device_code },
    );

    var attempts: usize = device.expires_in / device.interval;
    while (attempts > 0) : (attempts -= 1) {
        try io.sleep(.fromSeconds(device.interval), .boot);
        std.log.info("Poking authentication", .{});
        const t = try requestJson(MsToken, alloc, client, token_url, &form_headers, ms_body);

        if (t.access_token != null) return t;

        if (t.@"error") |err| {
            if (std.mem.eql(u8, err, "authorization_pending")) {
                std.log.info("Authentication is pending! Open {s} in your browser and enter {s} to confirm authorization!", .{ device.verification_uri, device.user_code });
                continue;
            }
            if (std.mem.eql(u8, err, "authorization_declined")) return error.AuthDeclined;
            if (std.mem.eql(u8, err, "expired_token")) return error.TokenExpired;
            if (std.mem.eql(u8, err, "bad_verification_code")) return error.BadCode;
            if (std.mem.eql(u8, err, "invalid_grant")) return error.InvalidGrant;
            return error.LoginFailed;
        }
    }
    return error.DeviceCodeExpired;
}

fn xboxAuth(alloc: Allocator, client: *std.http.Client, ms_token: MsToken) !XblToken {
    var buf: [8192]u8 = undefined;
    const xbl_body = try std.fmt.bufPrint(
        &buf,
        \\{{"Properties":{{"AuthMethod":"RPS","SiteName":"user.auth.xboxlive.com","RpsTicket":"d={s}"}},"RelyingParty":"http://auth.xboxlive.com","TokenType":"JWT"}}
    ,
        .{ms_token.access_token.?},
    );

    const url = std.Uri.parse("https://user.auth.xboxlive.com/user/authenticate") catch unreachable;
    return try requestJson(XblToken, alloc, client, url, &json_headers, xbl_body);
}

fn xstsAuth(alloc: Allocator, client: *std.http.Client, xbox_token: XblToken) !XstsToken {
    var buf: [8192]u8 = undefined;
    const xsts_body = try std.fmt.bufPrint(
        &buf,
        \\{{"Properties":{{"SandboxId":"RETAIL","UserTokens":["{s}"]}},"RelyingParty":"rp://api.minecraftservices.com/","TokenType":"JWT"}}
    ,
        .{xbox_token.Token},
    );

    const url = std.Uri.parse("https://xsts.auth.xboxlive.com/xsts/authorize") catch unreachable;
    return try requestJson(XstsToken, alloc, client, url, &json_headers, xsts_body);
}

fn login(alloc: Allocator, client: *std.http.Client, xsts_token: XstsToken) !Account {
    var buf: [8192]u8 = undefined;
    const login_body = try std.fmt.bufPrint(
        &buf,
        \\{{"identityToken":"XBL3.0 x={s};{s}"}}
    ,
        .{ xsts_token.DisplayClaims.xui[0].uhs, xsts_token.Token },
    );

    const url = std.Uri.parse("https://api.minecraftservices.com/authentication/login_with_xbox") catch unreachable;
    return try requestJson(Account, alloc, client, url, &json_headers, login_body);
}

fn getProfile(alloc: Allocator, client: *std.http.Client, account: Account) !Profile {
    var buf: [8192]u8 = undefined;
    const profile_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try std.fmt.bufPrint(&buf, "Bearer {s}", .{account.access_token}) },
    };

    const url = std.Uri.parse("https://api.minecraftservices.com/minecraft/profile") catch unreachable;
    return try requestJson(Profile, alloc, client, url, &profile_headers, null);
}

pub fn requestJson(T: type, arena: std.mem.Allocator, client: *std.http.Client, url: std.Uri, headers: []const std.http.Header, payload: ?[]const u8) !T {
    var req = try client.request(if (payload == null) .GET else .POST, url, .{ .extra_headers = headers });
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = try req.sendBodyUnflushed(&.{});

        try body.writer.writeAll(p);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [64]u8 = undefined;
    var compress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &compress_buf);
    var r = std.json.Reader.init(arena, reader);
    return std.json.parseFromTokenSourceLeaky(T, arena, &r, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
}

fn openUrl(io: Io, gpa: std.mem.Allocator, url: []const u8) !void {
    const argv = switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd => &[_][]const u8{
            "xdg-open",
            url,
        },
        .macos => &[_][]const u8{
            "open",
            url,
        },
        .windows => &[_][]const u8{
            "cmd",
            "/C",
            "start",
            "",
            url,
        },
        else => return error.UnsupportedOS,
    };
    const res = std.process.run(gpa, io, .{
        .expand_arg0 = .expand,
        .argv = argv,
    }) catch |err| {
        std.log.err("unable to open url {s} in browser; error: {t}", .{ url, err });
        return error.OpenFailed;
    };
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    if (res.term.exited != 0) {
        std.log.err("Unable to open url {s} in browser; stderr:\n{s}", .{ url, res.stderr });
        return error.OpenFailed;
    }
}

pub const Store = struct {
    // pub const GameProfile = struct {
    //     name: []const u8,
    //     type: []const u8,
    //     created: []const u8,
    //     lastUsed: []const u8,
    //     icon: []const u8,
    //     lastVersionId: []const u8,
    //     gameDir: []const u8,
    //     javaDir: []const u8,
    //     javaArgs: []const u8,
    //     logConfig: []const u8,
    //     logConfigIsXML: bool,
    //     resolution: struct {
    //         height: u32,
    //         width: u32,
    //     },
    // };
    // pub const Authentication = struct {
    //     accessToken: []const u8,
    //     username: []const u8,
    //
    //     profiles: std.json.ArrayHashMap([]const u8),
    // };
    // profiles: std.json.ArrayHashMap(GameProfile),
    // clientToken: []const u8,
    // authenticationDatabase: std.json.ArrayHashMap(Authentication),
    // launcherVersion: struct {
    //     name: []const u8,
    //     format: u32,
    //     profilesFormat: u32,
    // },
    // settings: struct {
    //     enableSnapshots: bool,
    //     enableAdvanced: bool,
    //     keepLauncherOpen: bool,
    //     showGameLog: bool,
    //     locale: []const u8,
    //     showMenu: bool,
    //     enableHistorical: bool,
    //     profileSorting: enum { byName, byLastPlayed },
    //     crashAssistance: bool,
    // },
    // enableAnalytics: bool,
    // analyticsToken: []const u8,
    // analyticsFailcount: u32,
    // selectedUser: struct {
    //     account: []const u8,
    //     profile: []const u8,
    // },
    //
    // pub const empty: Store = .{
    //     .profiles = .{ .map = .empty },
    //     .clientToken = "",
    //     .authenticationDatabase = .{ .map = .empty },
    //     .launcherVersion = .{ .name = "zmc", .format = 0, .profilesFormat = 0 },
    //     .settings = .{
    //         .enableSnapshots = true,
    //         .enableAdvanced = true,
    //         .keepLauncherOpen = false,
    //         .showGameLog = false,
    //         .locale = "en-us",
    //         .showMenu = false,
    //         .enableHistorical = true,
    //         .profileSorting = .byLastPlayed,
    //         .crashAssistance = false,
    //     },
    //     .enableAnalytics = false,
    //     .analyticsToken = "",
    //     .analyticsFailcount = 0,
    //     .selectedUser = .{
    //         .account = "",
    //         .profile = "",
    //     },
    // };

    // pub fn open(io: Io, alloc: Allocator, path: []const u8) !Store {
    //     const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    //     defer dir.close(io);
    //     const file = dir.openFile(io, "launcher_accounts.json", .{}) catch |err| switch (err) {
    //         error.FileNotFound => return .empty,
    //         else => |e| return e,
    //     };
    //     defer file.close(io);
    //     var buf: [1024]u8 = undefined;
    //     var reader = file.reader(io, &buf);
    //     const json_reader: std.json.Reader = .init(alloc, &reader.interface);
    //     return std.json.parseFromTokenSourceLeaky(Store, alloc, json_reader, .{});
    // }
    //
    // pub fn activate(store: *Store, alloc: Allocator, account: Authentication) !void {
    //     store.selectedUser.profile = account.profiles.map.keys()[0];
    //     store.selectedUser.account = store.selectedUser.profile;
    //     try store.authenticationDatabase.map.put(alloc, store.selectedUser.account, account);
    // }
    //
    // pub fn active(store: *Store) ?Authentication {
    //     store.authenticationDatabase.map.get(store.selectedUser.account);
    // }
    //
    // pub fn save(store: Store, io: Io, minecraft_folder: []const u8) !void {
    //     const dir = try Io.Dir.cwd().createDirPathOpen(io, minecraft_folder, .{});
    //     defer dir.close(io);
    //     const file = try dir.createFile(io, "launcher_accounts.json", .{});
    //     defer file.close(io);
    //     var buf: [1024]u8 = undefined;
    //     var writer = file.writer(io, &buf);
    //     var json_writer: std.json.Stringify = .{ .writer = &writer.interface };
    //     try json_writer.write(store);
    // }
    last_opened: Io.File,
    token_dir: Io.Dir,

    pub fn open(io: Io, cache_path: []const u8) !@This() {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
        defer dir.close(io);
        const cache_dir = try dir.createDirPathOpen(io, "zmc", .{});
        defer cache_dir.close(io);
        const last_opened = try cache_dir.createFile(io, "default", .{ .read = true, .truncate = false });
        errdefer last_opened.close(io);
        const token_dir = try cache_dir.createDirPathOpen(io, "tokens", .{ .open_options = .{ .iterate = true } });
        errdefer token_dir.close(io);
        return .{ .last_opened = last_opened, .token_dir = token_dir };
    }
    pub fn last(self: @This(), io: Io, buf: []u8) !?[]const u8 {
        var reader = self.last_opened.reader(io, &.{});
        const n = reader.interface.readSliceShort(buf) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        return if (n == 0) return null else buf[0..n];
    }

    pub fn read(self: @This(), io: Io, name: []const u8, buf: []u8) !?[]const u8 {
        return self.token_dir.readFile(io, name, buf) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }
    pub fn write(self: @This(), io: Io, name: []const u8, refresh_token: []const u8) !void {
        try self.token_dir.writeFile(io, .{ .sub_path = name, .data = refresh_token });
        try self.last_opened.writeStreamingAll(io, name);
    }

    pub fn list(self: @This()) !Io.Dir.Iterator {
        return self.token_dir.iterate();
    }

    pub fn deinit(self: @This(), io: Io) void {
        self.last_opened.close(io);
        self.token_dir.close(io);
    }
};
