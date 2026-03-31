const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const http_client = @import("llm/http_client.zig");
const build_info = @import("build_info");

const VERSION = build_info.version;

const GITHUB_RELEASES_URL = "https://api.github.com/repos/colus001/pls/releases/latest";
const INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/colus001/pls/main/install.sh";
const UPDATE_CHECK_INTERVAL_SECS: i64 = 24 * 60 * 60;

/// Parse a semver string "major.minor.patch" into three integers.
/// Returns null if parsing fails.
pub fn parseSemver(ver: []const u8) ?[3]u32 {
    var it = std.mem.splitScalar(u8, ver, '.');
    const major_str = it.next() orelse return null;
    const minor_str = it.next() orelse return null;
    const patch_str = it.next() orelse return null;
    const major = std.fmt.parseInt(u32, major_str, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return null;
    const patch = std.fmt.parseInt(u32, patch_str, 10) catch return null;
    return .{ major, minor, patch };
}

/// Returns true if `candidate` is strictly newer than `current`.
pub fn semverIsNewer(current: []const u8, candidate: []const u8) bool {
    const cur = parseSemver(current) orelse return false;
    const can = parseSemver(candidate) orelse return false;
    if (can[0] != cur[0]) return can[0] > cur[0];
    if (can[1] != cur[1]) return can[1] > cur[1];
    return can[2] > cur[2];
}

/// Check GitHub for a newer release. Shows an upgrade hint if one is found.
/// Uses a cache file (~/.config/pls/.last_update_check) to rate-limit checks
/// to once per 24 hours. All failures are silently ignored.
pub fn checkForUpdates(allocator: Allocator, stderr: anytype) void {
    checkForUpdatesInner(allocator, stderr) catch {};
}

fn checkForUpdatesInner(allocator: Allocator, stderr: anytype) !void {
    const config_dir = config_mod.getConfigDir(allocator) catch return;
    defer allocator.free(config_dir);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/.last_update_check", .{config_dir});
    defer allocator.free(cache_path);

    // Check if 24 hours have passed since the last check.
    const now_secs: i64 = @intCast(std.time.timestamp());

    if (std.fs.openFileAbsolute(cache_path, .{})) |f| {
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = f.read(&buf) catch 0;
        if (n > 0) {
            const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
            if (std.fmt.parseInt(i64, trimmed, 10)) |last_check| {
                if (now_secs - last_check < UPDATE_CHECK_INTERVAL_SECS) return;
            } else |_| {}
        }
    } else |_| {}

    // Write current timestamp to cache before making the network request.
    // This prevents hammering the API even when the user is offline.
    if (std.fs.openFileAbsolute(cache_path, .{ .mode = .write_only })) |f| {
        defer f.close();
        f.writer().print("{d}\n", .{now_secs}) catch {};
    } else |_| {
        // Cache file doesn't exist yet — create it (dir must already exist).
        if (std.fs.createFileAbsolute(cache_path, .{})) |f| {
            defer f.close();
            f.writer().print("{d}\n", .{now_secs}) catch {};
        } else |_| {}
    }

    // Fetch the latest release tag from GitHub.
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "pls-cli/" ++ VERSION },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
    };
    const body = http_client.get(allocator, GITHUB_RELEASES_URL, &headers) catch return;
    defer allocator.free(body);

    // Parse JSON and extract tag_name.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const tag_name = switch (root.get("tag_name") orelse return) {
        .string => |s| s,
        else => return,
    };

    // Strip leading "v" if present.
    const latest = if (tag_name.len > 0 and tag_name[0] == 'v') tag_name[1..] else tag_name;

    if (!semverIsNewer(VERSION, latest)) return;

    // Print upgrade hint — platform-specific.
    const builtin = @import("builtin");
    const upgrade_cmd = switch (builtin.os.tag) {
        .macos => "brew upgrade pls",
        else => "curl -sSfL " ++ INSTALL_SCRIPT_URL ++ " | sh",
    };

    try stderr.print(
        "\x1b[33mA new version of pls is available: v{s} (current: v{s})\x1b[0m\n" ++
            "\x1b[33mTo upgrade: {s}\x1b[0m\n\n",
        .{ latest, VERSION, upgrade_cmd },
    );
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "semverIsNewer returns true when candidate is newer" {
    try std.testing.expect(semverIsNewer("0.3.1", "0.4.0"));
    try std.testing.expect(semverIsNewer("0.3.1", "0.3.2"));
    try std.testing.expect(semverIsNewer("0.9.9", "1.0.0"));
    try std.testing.expect(semverIsNewer("1.2.3", "2.0.0"));
}

test "semverIsNewer returns false when candidate is same or older" {
    try std.testing.expect(!semverIsNewer("0.3.1", "0.3.1"));
    try std.testing.expect(!semverIsNewer("0.4.0", "0.3.9"));
    try std.testing.expect(!semverIsNewer("1.0.0", "0.9.9"));
    try std.testing.expect(!semverIsNewer("2.0.0", "1.9.9"));
}

test "semverIsNewer returns false on malformed versions" {
    try std.testing.expect(!semverIsNewer("bad", "0.4.0"));
    try std.testing.expect(!semverIsNewer("0.3.1", "bad"));
    try std.testing.expect(!semverIsNewer("", ""));
}

test "parseSemver parses valid version strings" {
    const v = parseSemver("1.2.3") orelse unreachable;
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 3), v[2]);
}

test "parseSemver returns null for invalid strings" {
    try std.testing.expect(parseSemver("1.2") == null);
    try std.testing.expect(parseSemver("abc") == null);
    try std.testing.expect(parseSemver("") == null);
}
