const std = @import("std");
const Io = std.Io;
last_opened: Io.File,
token_dir: Io.Dir,

pub fn init(io: Io, cache_path: []const u8) !@This() {
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
