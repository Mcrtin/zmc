const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");
const mojang = @import("mojang.zig");

const CLIENT_ID = "708e91b5-99f8-4a1d-80ec-e746cbb24771";
const SCOPE = "XboxLive.signin offline_access";

const DEVICE_CODE_URL = std.Uri.parse("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode") catch unreachable;
const TOKEN_URL = std.Uri.parse("https://login.microsoftonline.com/consumers/oauth2/v2.0/token") catch unreachable;
const XBL_AUTH_URL = std.Uri.parse("https://user.auth.xboxlive.com/user/authenticate") catch unreachable;
const XSTS_AUTH_URL = std.Uri.parse("https://xsts.auth.xboxlive.com/xsts/authorize") catch unreachable;
const MC_LOGIN_URL = std.Uri.parse("https://api.minecraftservices.com/authentication/login_with_xbox") catch unreachable;
const MC_PROFILE_URL = std.Uri.parse("https://api.minecraftservices.com/minecraft/profile") catch unreachable;

const json_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Accept", .value = "application/json" },
};
const form_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
};

const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32, // seconds
    expires_in: u32, // seconds
};

const MsToken = struct {
    access_token: ?[]const u8 = null,
};

const XblToken = struct {
    token: []const u8,
};

const XstsToken = struct {
    Token: []const u8,
    DisplayClaims: struct {
        xui: []const struct {
            uhs: []const u8,
        },
    },
};
const McLogin = struct {
    access_token: []const u8,
};

const Profile = struct {
    name: []u8,
    id: []u8,
};

pub fn authenticate(io: Io, gpa: std.mem.Allocator, client: *std.http.Client) !mojang.Session {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const device_body = "client_id=" ++ CLIENT_ID ++ "&scope=" ++ SCOPE;
    const device = try http.requestJson(DeviceCodeResponse, alloc, client, DEVICE_CODE_URL, &form_headers, device_body);

    std.log.info("Opening {s}. enter code: {s}", .{ device.verification_uri, device.user_code });
    try openUrl(io, gpa, device.verification_uri);

    var buf: [1024]u8 = undefined;
    const ms_body = try std.fmt.bufPrint(
        &buf,
        "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id={s}&device_code={s}",
        .{ CLIENT_ID, device.device_code },
    );

    const ms_token = blk: {
        for (0..device.expires_in / device.interval) |_| {
            try io.sleep(.fromSeconds(device.interval), .boot);
            const t = try http.requestJson(MsToken, alloc, client, TOKEN_URL, &form_headers, ms_body);
            break :blk t;
        } else return error.DeviceCodeExpired;
    };

    const xbl_body = try std.fmt.bufPrint(
        &buf,
        \\{{"Properties":{{"AuthMethod":"RPS","SiteName":"user.auth.xboxlive.com","RpsTicket":"d={s}"}},"RelyingParty":"http://auth.xboxlive.com","TokenType":"JWT"}}
    ,
        .{ms_token.access_token.?},
    );

    const xbl_token = try http.requestJson(XblToken, alloc, client, XBL_AUTH_URL, &json_headers, xbl_body);

    const xsts_body = try std.fmt.bufPrint(
        &buf,
        \\{{"Properties":{{"SandboxId":"RETAIL","UserTokens":["{s}"]}},"RelyingParty":"rp://api.minecraftservices.com/","TokenType":"JWT"}}
    ,
        .{xbl_token.token},
    );

    const xsts_token = try http.requestJson(XstsToken, alloc, client, XSTS_AUTH_URL, &json_headers, xsts_body);

    const login_body = try std.fmt.bufPrint(
        &buf,
        \\{{"identityToken":"XBL3.0 x={s};{s}"}}
    ,
        .{ xsts_token.DisplayClaims.xui[0].uhs, xsts_token.Token },
    );

    const login = try http.requestJson(McLogin, alloc, client, MC_LOGIN_URL, &json_headers, login_body);

    const profile_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try std.fmt.bufPrint(&buf, "Bearer {s}", .{login.access_token}) },
    };

    const profile = try http.requestJson(Profile, alloc, client, MC_PROFILE_URL, &profile_headers, null);

    return mojang.Session{
        .username = try gpa.dupe(u8, profile.name),
        .uuid = try gpa.dupe(u8, profile.id),
        .access_token = try gpa.dupe(u8, login.access_token),
        .user_type = .msa,
    };
}

pub fn openUrl(io: Io, gpa: std.mem.Allocator, url: []const u8) !void {
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
    const res = try std.process.run(gpa, io, .{
        .expand_arg0 = .expand,
        .argv = argv,
    });
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    if (res.term.exited != 0) {
        std.log.err("Unable to open url {s} in browser; stderr:\n{s}", .{ url, res.stderr });
        return error.OpenFailed;
    }
}
