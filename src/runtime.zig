const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");
const iofs = @import("iofs.zig");

// The official launcher doesn't rely on a system-installed JDK at all --
// it downloads its own, per Minecraft-version-appropriate JRE from a
// separate Mojang manifest, because the required Java version varies by
// Minecraft version and most users don't have a matching JDK installed.
// We do the same here, so `zmc` works out of the box without the user
// needing to have Java set up correctly (or at all).
//
// The index below is a fixed, well-known URL (documented by the
// unofficial wiki.vg protocol docs) that Mojang's own launcher reads from;
// it's not something that rotates per-request.
const RUNTIME_INDEX_URL = "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json";

fn platformKey() []const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .aarch64 => "windows-arm64",
            .x86 => "windows-x86",
            else => "windows-x64",
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "mac-os-arm64",
            else => "mac-os",
        },
        else => switch (builtin.cpu.arch) {
            .x86 => "linux-i386",
            else => "linux",
        },
    };
}

/// Ensures Mojang's bundled JRE for this version is present under
/// <mc_root>/runtime/<component>/<platform>/, downloading it on first use,
/// and returns an owned path to its `java` executable.
///
/// Returns null (not an error) if this version predates the `javaVersion`
/// field (very old versions -- caller should fall back to a system java in
/// that case), or if this platform/arch simply isn't published for the
/// needed component.
pub fn ensureJavaRuntime(
    io: Io,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    mc_root: []const u8,
    version_json: std.json.Value,
) !?[]u8 {
    const java_version_val = version_json.object.get("javaVersion") orelse return null;
    const component = java_version_val.object.get("component").?.string;

    const runtime_dir = try std.fs.path.join(allocator, &.{ mc_root, "runtime", component, platformKey() });
    defer allocator.free(runtime_dir);

    const java_bin_rel = if (builtin.os.tag == .windows) "bin/java.exe" else "bin/java";
    const java_bin_path = try std.fs.path.join(allocator, &.{ runtime_dir, java_bin_rel });

    if (iofs.exists(io, java_bin_path)) return java_bin_path;

    const index_body = try http.get(io, allocator, client, RUNTIME_INDEX_URL);
    defer allocator.free(index_body);
    const index_parsed = try std.json.parseFromSlice(std.json.Value, allocator, index_body, .{});
    defer index_parsed.deinit();

    const platform_obj = index_parsed.value.object.get(platformKey()) orelse {
        allocator.free(java_bin_path);
        return null;
    };
    const component_arr = platform_obj.object.get(component) orelse {
        allocator.free(java_bin_path);
        return null;
    };
    if (component_arr.array.items.len == 0) {
        allocator.free(java_bin_path);
        return null;
    }

    const manifest_url = component_arr.array.items[0].object.get("manifest").?.object.get("url").?.string;

    std.log.info("Downloading Java runtime ({s}, {s})...", .{ component, platformKey() });

    const manifest_body = try http.get(io, allocator, client, manifest_url);
    defer allocator.free(manifest_body);
    const manifest_parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_body, .{});
    defer manifest_parsed.deinit();

    const files = manifest_parsed.value.object.get("files").?.object;
    var it = files.iterator();
    while (it.next()) |entry| {
        const rel_path = entry.key_ptr.*;
        const file_obj = entry.value_ptr.object;
        const file_type = file_obj.get("type").?.string;

        const dest = try std.fs.path.join(allocator, &.{ runtime_dir, rel_path });
        defer allocator.free(dest);

        if (std.mem.eql(u8, file_type, "directory")) {
            try iofs.makePath(io, dest);
        } else if (std.mem.eql(u8, file_type, "file")) {
            const url = file_obj.get("downloads").?.object.get("raw").?.object.get("url").?.string;
            if (!iofs.exists(io, dest)) try http.downloadToFile(io, client, url, dest);

            const executable = if (file_obj.get("executable")) |e| e.bool else false;
            if (executable) iofs.makeExecutable(io, dest) catch |err| {
                std.log.warn("Could not mark {s} executable: {s}", .{ dest, @errorName(err) });
            };
        }
        // "link" entries (a handful of internal JRE symlinks) aren't
        // recreated -- known limitation, see README. In practice the java
        // binary itself is a real file in every runtime we've seen, so
        // this doesn't block launching.
    }

    return java_bin_path;
}
