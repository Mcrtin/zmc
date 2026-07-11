const Io = std.Io;
const std = @import("std");

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
    return std.json.parseFromTokenSourceLeaky(T, arena, &r, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |err| switch (err) {
        error.UnknownField => {
            const next = try std.json.innerParse(std.json.Value, arena, &r, .{ .max_value_len = 100 });
            std.debug.print("next token: \n", .{});
            printVal(next);

            return err;
        },
        else => |e| return e,
    };
}
fn printVal(val: std.json.Value) void {
    switch (val) {
        .string => |s| std.debug.print("{s}", .{s}),
        .bool => |b| std.debug.print("{s}", .{if (b) "true" else "false"}),
        .float => |f| std.debug.print("{d}", .{f}),
        .integer => |i| std.debug.print("{d}", .{i}),
        .null => std.debug.print("null", .{}),
        .number_string => |s| std.debug.print("{s}", .{s}),
        .array => |a| {
            std.debug.print("[", .{});
            for (a.items) |item| {
                printVal(item);
                std.debug.print(",\n", .{});
            }
            std.debug.print("]", .{});
        },
        .object => |s| {
            std.debug.print("{{", .{});
            var it = s.iterator();
            while (it.next()) |entry| {
                std.debug.print("{s} = ", .{entry.key_ptr.*});
                printVal(entry.value_ptr.*);
                std.debug.print(",\n", .{});
            }
            std.debug.print("}}", .{});
        },
    }
}

// TODO: make it able to detect unfinished downloads
pub fn downloadToFile(
    client: *std.http.Client,
    url: []const u8,
    sha1: []const u8,
    writer: *Io.Writer,
) !void {
    defer writer.flush() catch {};
    var hash_buf: [1024]u8 = undefined;
    var hasher: std.crypto.hash.Sha1 = .init(.{});
    var hashing_writer = writer.hashed(&hasher, &hash_buf);
    const res = try client.fetch(.{ .response_writer = &hashing_writer.writer, .location = .{ .url = url } });
    try hashing_writer.writer.flush();
    try writer.flush();
    var print_buf: [100]u8 = undefined;
    const sha1_res = std.fmt.bufPrint(&print_buf, "{x}", .{hashing_writer.hasher.finalResult()}) catch unreachable;

    if (res.status.class() != .success) return error.DownloadError;
    if (!std.mem.eql(u8, sha1, sha1_res)) {
        std.log.err("hash mismatch: got: {s} expected: {s}", .{ sha1_res, sha1 });
        return error.ChecksumMismatch;
    }
}
