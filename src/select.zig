const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

// ---------------------------------------------------------------------
// HIGHEST-RISK FILE IN THIS PROJECT. vaxis is a fast-moving library and,
// per its own README, has historically tracked whichever Zig version was
// current at the time (0.13 -> 0.14 -> 0.15 snapshots seen in its docs) --
// there's a real chance it hasn't caught up to 0.16's std.Io rewrite yet
// by the time you build this. If `zig build` fails deep inside vaxis
// itself (not this file), that's almost certainly why; check vaxis's repo
// for a 0.16-compatible branch/tag before debugging this file.
//
// Everything below is written against vaxis's documented low-level API
// (Tty, Vaxis, Loop(Event), Window.writeCell). Field/method names on
// Style, Key, and Window are best-effort from public examples -- fix up
// locally against whatever vaxis version you actually land on.
// ---------------------------------------------------------------------

pub const Option = struct {
    label: []const u8,
    hint: []const u8 = "", // shown dim, after the label (e.g. an email)
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

/// gh-cli style "pick one" prompt:
///   Select an option: <filter text>
///     option one
///   > option two   <- currently selected
///     option three
///
/// Type to filter, Up/Down (or Ctrl-P/Ctrl-N) to move, Enter to confirm,
/// Esc/Ctrl-C to cancel. Returns the index into `options`, or null if
/// cancelled.
pub fn select(io: Io, allocator: std.mem.Allocator, prompt: []const u8, options: []const Option) !?usize {
    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    defer vx.exitAltScreen(tty.anyWriter()) catch {};
    try vx.queryTerminal(tty.anyWriter(), .fromSeconds(1));

    var query = std.ArrayListUnmanaged(u8){};
    defer query.deinit(allocator);

    const filtered = try allocator.alloc(usize, options.len);
    defer allocator.free(filtered);
    var filtered_len: usize = options.len;
    for (0..options.len) |i| filtered[i] = i;

    var cursor: usize = 0;
    var result: ?usize = null;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                    return null;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (filtered_len > 0) result = filtered[cursor];
                    return result;
                } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                    if (cursor > 0) cursor -= 1;
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
                    if (filtered_len > 0 and cursor + 1 < filtered_len) cursor += 1;
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    if (query.items.len > 0) query.items.len -= 1;
                    refilter(options, query.items, filtered, &filtered_len);
                    cursor = 0;
                } else if (key.text) |text| {
                    try query.appendSlice(allocator, text);
                    refilter(options, query.items, filtered, &filtered_len);
                    cursor = 0;
                }
            },
        }

        draw(vx, prompt, query.items, options, filtered[0..filtered_len], cursor);
        try vx.render(tty.anyWriter());
    }
}

fn refilter(options: []const Option, query: []const u8, filtered: []usize, filtered_len: *usize) void {
    var n: usize = 0;
    for (options, 0..) |opt, i| {
        if (query.len == 0 or containsIgnoreCase(opt.label, query)) {
            filtered[n] = i;
            n += 1;
        }
    }
    filtered_len.* = n;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn draw(vx: vaxis.Vaxis, prompt: []const u8, query: []const u8, options: []const Option, filtered: []const usize, cursor: usize) void {
    const win = vx.window();
    win.clear();

    writeText(win, 0, 0, prompt, .{ .bold = true });
    writeText(win, @intCast(prompt.len + 1), 0, query, .{});

    for (filtered, 0..) |opt_idx, row| {
        const opt = options[opt_idx];
        const is_selected = row == cursor;

        writeText(win, 0, @intCast(row + 2), if (is_selected) "> " else "  ", .{
            .fg = if (is_selected) .{ .index = 2 } else .default,
        });
        writeText(win, 2, @intCast(row + 2), opt.label, .{
            .bold = is_selected,
            .reverse = is_selected,
        });
        if (opt.hint.len > 0) {
            writeText(win, @intCast(2 + opt.label.len + 1), @intCast(row + 2), opt.hint, .{ .dim = true });
        }
    }

    if (filtered.len == 0) {
        writeText(win, 0, 2, "(no matches)", .{ .dim = true });
    }
}

fn writeText(win: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    var c: u16 = col;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepointSlice()) |grapheme| {
        win.writeCell(c, row, .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style });
        c += 1;
    }
}
