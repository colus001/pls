const std = @import("std");
const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const init_mod = @import("init.zig");
const config_editor = @import("config_editor.zig");
const history_mod = @import("history.zig");
const build_info = @import("build_info");
const http_client = @import("llm/http_client.zig");
const updater = @import("updater.zig");

const VERSION = build_info.version;

const SPONSOR_URL = "https://github.com/sponsors/colus001";

fn printSponsorMessage(stderr: anytype) void {
    stderr.writeAll("\x1b[36m\xe2\x99\xa1 Support free proxy of pls: " ++ SPONSOR_URL ++ "\x1b[0m\n") catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        // Check if stdin has piped data
        const stdin_task = try readStdinIfPiped(allocator);
        if (stdin_task) |task| {
            defer allocator.free(task);
            try runTask(allocator, stderr, task, .all, false, null, null, 20);
            return;
        }
        try printUsage(stdout);
        return;
    }

    // Parse flags and collect the task
    var confirm_mode_override: ?config_mod.ConfirmMode = null;
    var dry_run = false;
    var provider_override: ?[]const u8 = null;
    var model_override: ?[]const u8 = null;
    var max_turns: usize = 20;
    var task_parts: std.ArrayList([]const u8) = .empty;
    defer task_parts.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "init")) {
            try init_mod.runSetup(allocator);
            return;
        } else if (std.mem.eql(u8, arg, "history")) {
            try runHistory(allocator, stdout, stderr);
            return;
        } else if (std.mem.eql(u8, arg, "usage") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "reset")) {
            try resetUsage(allocator, stdout, stderr);
            return;
        } else if (std.mem.eql(u8, arg, "usage")) {
            try checkUsage(allocator, stdout, stderr);
            return;
        } else if (std.mem.eql(u8, arg, "config") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "show")) {
            try showConfig(allocator, stdout, stderr);
            return;
        } else if (std.mem.eql(u8, arg, "config") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "reset")) {
            try resetConfig(allocator, stderr);
            return;
        } else if (std.mem.eql(u8, arg, "config")) {
            try config_editor.runEditor(allocator);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.print("pls v{s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            confirm_mode_override = .none;
        } else if (std.mem.startsWith(u8, arg, "--confirm=")) {
            const val = arg["--confirm=".len..];
            if (config_mod.ConfirmMode.fromString(val)) |m| {
                confirm_mode_override = m;
            } else {
                try stderr.print("Unknown confirm mode: {s} (expected: all, destructive, none)\n", .{val});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--confirm")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("--confirm requires a value (all, destructive, none)\n");
                return;
            }
            if (config_mod.ConfirmMode.fromString(args[i])) |m| {
                confirm_mode_override = m;
            } else {
                try stderr.print("Unknown confirm mode: {s} (expected: all, destructive, none)\n", .{args[i]});
                return;
            }
        } else if (std.mem.startsWith(u8, arg, "--provider=")) {
            provider_override = arg["--provider=".len..];
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("--provider requires a value\n");
                return;
            }
            provider_override = args[i];
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model_override = arg["--model=".len..];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("--model requires a value\n");
                return;
            }
            model_override = args[i];
        } else if (std.mem.startsWith(u8, arg, "--max-turns=")) {
            const val = arg["--max-turns=".len..];
            max_turns = std.fmt.parseInt(usize, val, 10) catch {
                try stderr.print("Invalid --max-turns value: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("--max-turns requires a value\n");
                return;
            }
            max_turns = std.fmt.parseInt(usize, args[i], 10) catch {
                try stderr.print("Invalid --max-turns value: {s}\n", .{args[i]});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            try task_parts.append(allocator, arg);
        }
    }

    // If no task args, check stdin pipe
    var task: []const u8 = undefined;
    var task_owned = false;

    if (task_parts.items.len == 0) {
        const stdin_task = try readStdinIfPiped(allocator);
        if (stdin_task) |t| {
            task = t;
            task_owned = true;
        } else {
            try printUsage(stdout);
            return;
        }
    } else {
        task = try std.mem.join(allocator, " ", task_parts.items);
        task_owned = true;
    }
    defer if (task_owned) allocator.free(task);

    try runTask(allocator, stderr, task, confirm_mode_override, dry_run, provider_override, model_override, max_turns);
}

fn runTask(
    allocator: std.mem.Allocator,
    stderr: std.fs.File.DeprecatedWriter,
    task: []const u8,
    confirm_mode_override: ?config_mod.ConfirmMode,
    dry_run: bool,
    provider_override: ?[]const u8,
    model_override: ?[]const u8,
    max_turns: usize,
) !void {
    // Load config
    var cfg = config_mod.load(allocator) catch |err| {
        try stderr.print("Error loading config: {}\n", .{err});
        try stderr.writeAll("Run `pls init` to set up your configuration.\n");
        return;
    };
    defer cfg.deinit();

    // Apply per-invocation overrides
    if (provider_override) |p| {
        if (config_mod.Provider.fromString(p)) |prov| {
            cfg.provider = prov;
        } else {
            try stderr.print("Unknown provider: {s} (expected: proxy, anthropic, openai, gemini, ollama)\n", .{p});
            return;
        }
    }

    if (model_override) |m| {
        const owned = try cfg.ownString(m);
        switch (cfg.provider) {
            .proxy => cfg.proxy_model = owned,
            .anthropic => cfg.anthropic_model = owned,
            .openai => cfg.openai_model = owned,
            .gemini => cfg.gemini_model = owned,
            .ollama => cfg.ollama_model = owned,
        }
    }

    // Determine effective confirm mode: CLI flag > config file
    const confirm_mode = confirm_mode_override orelse cfg.confirm_mode;

    // Validate that we have an API key (unless using proxy or Ollama)
    if (cfg.provider.requiresApiKey() and cfg.getApiKey() == null) {
        try stderr.print("No API key configured for {s}.\n", .{cfg.provider.toString()});
        try stderr.writeAll("Run `pls init` to set up your configuration.\n");
        return;
    }

    // Check for a newer release (best-effort, once per 24 h)
    updater.checkForUpdates(allocator, stderr);

    // Capture timestamp and cwd before running the agent
    const session_timestamp = history_mod.currentTimestamp(allocator) catch null;
    defer if (session_timestamp) |ts| allocator.free(ts);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const session_cwd = std.posix.getcwd(&cwd_buf) catch std.posix.getenv("PWD") orelse "";

    // Run the agent
    var agent = try agent_mod.Agent.init(allocator, &cfg, .{
        .confirm_mode = confirm_mode,
        .dry_run = dry_run,
        .max_turns = max_turns,
    });
    defer agent.deinit();

    agent.run(task) catch |err| {
        // RateLimited: proxy.zig already printed a descriptive message; skip generic prefix
        if (err != error.RateLimited) {
            try stderr.print("\nError: {}\n", .{err});
        }
        switch (err) {
            error.NoApiKey => try stderr.writeAll("Run `pls init` to configure your API key.\n"),
            error.HttpError => try stderr.writeAll("Failed to connect to the LLM API. Check your network.\n"),
            error.ApiError => try stderr.writeAll("The LLM API returned an error. Check your API key and model.\n"),
            error.RateLimited => printSponsorMessage(stderr),
            error.BudgetExceeded => printSponsorMessage(stderr),
            error.InvalidResponse => try stderr.writeAll("The API returned an unexpected response format. See above for details.\n"),
            error.JsonParseError => try stderr.writeAll("Failed to parse the API response. See above for details.\n"),
            else => {},
        }
    };

    // Record history entry (best-effort; failure is non-fatal)
    history_mod.appendEntry(allocator, .{
        .timestamp = session_timestamp orelse "unknown",
        .cwd = session_cwd,
        .task = task,
        .commands = agent.executed_commands.items,
    }) catch {};
}

fn checkUsage(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    var cfg = config_mod.load(allocator) catch |err| {
        try stderr.print("Error loading config: {}\n", .{err});
        try stderr.writeAll("Run `pls init` to set up your configuration.\n");
        return;
    };
    defer cfg.deinit();

    if (cfg.provider != .proxy) {
        try stderr.print("Rate limit usage is only available for the free proxy (current provider: {s}).\n", .{cfg.provider.toString()});
        return;
    }

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/rate-limit", .{cfg.proxy_url});
    defer allocator.free(url);

    // Fetch proxy version (best-effort; failure is non-fatal)
    const version_url = try std.fmt.allocPrint(allocator, "{s}/v1/version", .{cfg.proxy_url});
    defer allocator.free(version_url);
    const proxy_version: ?[]const u8 = http_client.get(allocator, version_url, &.{}) catch null;
    defer if (proxy_version) |v| allocator.free(v);

    const body = http_client.get(allocator, url, &.{}) catch |err| {
        switch (err) {
            error.HttpError => try stderr.print("Failed to connect to proxy: {s}\n", .{cfg.proxy_url}),
            error.ApiError => try stderr.writeAll("Proxy returned an error.\n"),
            else => try stderr.print("Error: {}\n", .{err}),
        }
        return;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try stderr.writeAll("Failed to parse rate limit response.\n");
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try stderr.writeAll("Unexpected response format.\n");
            return;
        },
    };

    // Extract the three tier objects
    const burst = if (root.get("burst")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;
    const hourly = if (root.get("hourly")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;
    const daily = if (root.get("daily")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;

    if (burst == null or hourly == null or daily == null) {
        try stderr.writeAll("Incomplete rate limit response.\n");
        return;
    }

    const ip = if (root.get("ip")) |v| switch (v) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    try stdout.writeAll("\n");
    if (proxy_version) |v| {
        const ver = std.mem.trim(u8, v, " \t\r\n");
        try stdout.print("  pls proxy usage  (v{s} \xc2\xb7 {s})\n", .{ ver, ip });
    } else {
        try stdout.print("  pls proxy usage  ({s})\n", .{ip});
    }
    try stdout.writeAll("  ----------------\n");

    try printUsageTier(stdout, allocator, "burst ", burst.?);
    try printUsageTier(stdout, allocator, "hourly", hourly.?);
    try printUsageTier(stdout, allocator, "daily ", daily.?);

    try stdout.writeAll("\n");
}

fn resetUsage(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    var cfg = config_mod.load(allocator) catch |err| {
        try stderr.print("Error loading config: {}\n", .{err});
        return;
    };
    defer cfg.deinit();

    if (cfg.provider != .proxy) {
        try stderr.print("Rate limit reset is only available for the free proxy (current provider: {s}).\n", .{cfg.provider.toString()});
        return;
    }

    // Require admin key from config or ADMIN_KEY env var
    const admin_key = cfg.admin_key orelse {
        try stderr.writeAll("Admin key is not configured. Set admin_key in config or ADMIN_KEY env var.\n");
        return;
    };

    // Fetch current IP from /v1/rate-limit
    const info_url = try std.fmt.allocPrint(allocator, "{s}/v1/rate-limit", .{cfg.proxy_url});
    defer allocator.free(info_url);

    const info_body = http_client.get(allocator, info_url, &.{}) catch |err| {
        switch (err) {
            error.HttpError => try stderr.print("Failed to connect to proxy: {s}\n", .{cfg.proxy_url}),
            else => try stderr.writeAll("Failed to fetch current rate limit info.\n"),
        }
        return;
    };
    defer allocator.free(info_body);

    const info_parsed = std.json.parseFromSlice(std.json.Value, allocator, info_body, .{}) catch {
        try stderr.writeAll("Failed to parse rate limit response.\n");
        return;
    };
    defer info_parsed.deinit();

    const ip = blk: {
        const root = switch (info_parsed.value) {
            .object => |o| o,
            else => break :blk "unknown",
        };
        break :blk if (root.get("ip")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";
    };

    if (std.mem.eql(u8, ip, "unknown")) {
        try stderr.writeAll("Could not determine current IP from proxy.\n");
        return;
    }

    // Build Authorization header
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{admin_key});
    defer allocator.free(auth_value);

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_value },
    };

    // DELETE /v1/rate-limit/:ip
    const delete_url = try std.fmt.allocPrint(allocator, "{s}/v1/rate-limit/{s}", .{ cfg.proxy_url, ip });
    defer allocator.free(delete_url);

    _ = http_client.delete(allocator, delete_url, &headers) catch |err| {
        switch (err) {
            error.HttpError => try stderr.print("Failed to connect to proxy: {s}\n", .{cfg.proxy_url}),
            error.ApiError => try stderr.writeAll("Reset failed. Check your PLS_ADMIN_KEY.\n"),
            else => try stderr.print("Error: {}\n", .{err}),
        }
        return;
    };

    try stdout.print("Rate limit reset for {s}.\n", .{ip});
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn printUsageTier(stdout: anytype, allocator: std.mem.Allocator, label: []const u8, obj: std.json.ObjectMap) !void {
    const used = getJsonInt(obj, "used") orelse 0;
    const limit = getJsonInt(obj, "limit") orelse 0;
    const remaining = getJsonInt(obj, "remaining") orelse 0;
    const reset_secs = getJsonInt(obj, "reset_after_seconds") orelse 0;

    const reset_str = try formatSeconds(allocator, @intCast(@max(reset_secs, 0)));
    defer allocator.free(reset_str);

    // Colour the used/limit portion: green when healthy, yellow near limit, red at limit
    const color: []const u8 = if (limit > 0 and remaining == 0)
        "\x1b[31m" // red — exhausted
    else if (limit > 0 and remaining * 5 <= limit)
        "\x1b[33m" // yellow — ≤20% left
    else
        "\x1b[32m"; // green — healthy
    const reset_color = "\x1b[0m";

    try stdout.print("  {s}  {s}{d}/{d}{s}  ({d} remaining, resets in {s})\n", .{
        label,
        color,
        used,
        limit,
        reset_color,
        remaining,
        reset_str,
    });
}

fn formatSeconds(allocator: std.mem.Allocator, secs: u64) ![]const u8 {
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    if (h > 0) {
        return std.fmt.allocPrint(allocator, "{d}h {d}m", .{ h, m });
    } else if (m > 0) {
        return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ m, s });
    } else {
        return std.fmt.allocPrint(allocator, "{d}s", .{s});
    }
}

fn runHistory(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    const entries = history_mod.loadEntries(allocator, 20) catch |err| {
        try stderr.print("Error loading history: {}\n", .{err});
        return;
    };
    defer {
        for (entries) |entry| history_mod.freeEntry(allocator, entry);
        allocator.free(entries);
    }

    if (entries.len == 0) {
        try stdout.writeAll("No history yet. Run a task with `pls <task>` to get started.\n");
        return;
    }

    const home = std.posix.getenv("HOME") orelse "";

    try writeHistoryEntries(allocator, stdout, entries, home);
}

fn writeHistoryEntries(allocator: std.mem.Allocator, stdout: anytype, entries: []const history_mod.HistoryEntry, home: []const u8) !void {
    try stdout.writeByte('\n');
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];

        // Display timestamp: "2026-03-30T14:23:00Z" -> "2026-03-30 14:23"
        var ts_buf = [_]u8{' '} ** 16;
        const ts_len = @min(entry.timestamp.len, 16);
        @memcpy(ts_buf[0..ts_len], entry.timestamp[0..ts_len]);
        if (ts_len > 10) ts_buf[10] = ' '; // replace 'T' with space
        const ts_display: []const u8 = &ts_buf;

        // Shorten cwd: replace HOME prefix with ~
        const display_cwd = if (home.len > 0 and std.mem.startsWith(u8, entry.cwd, home))
            try std.fmt.allocPrint(allocator, "~{s}", .{entry.cwd[home.len..]})
        else
            try allocator.dupe(u8, entry.cwd);
        defer allocator.free(display_cwd);

        try stdout.print("[{s}] {s}\n", .{ ts_display, display_cwd });
        try stdout.print("  Task: {s}\n", .{entry.task});

        if (entry.commands.len > 0) {
            try stdout.writeAll("  Commands:\n");
            for (entry.commands) |cmd| {
                var lines = std.mem.splitScalar(u8, cmd, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    try stdout.print("    $ {s}\n", .{trimmed});
                }
            }
        }

        try stdout.writeByte('\n');
    }
}

fn showConfig(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    var cfg = config_mod.load(allocator) catch |err| {
        try stderr.print("Error loading config: {}\n", .{err});
        try stderr.writeAll("Run `pls init` to set up your configuration.\n");
        return;
    };
    defer cfg.deinit();

    try stdout.writeAll("\n  pls configuration\n");
    try stdout.writeAll("  -----------------\n");
    try stdout.print("  provider      = {s}\n", .{cfg.provider.toString()});
    try stdout.print("  confirm_mode  = {s}\n", .{cfg.confirm_mode.toString()});
    try stdout.print("  model         = {s}\n", .{cfg.getModel()});

    // Show API key masked
    const key = cfg.getApiKey();
    if (key) |k| {
        if (k.len > 8) {
            try stdout.print("  api_key       = {s}...{s}\n", .{ k[0..4], k[k.len - 4 ..] });
        } else if (k.len > 0) {
            try stdout.writeAll("  api_key       = ****\n");
        } else {
            try stdout.writeAll("  api_key       = (empty)\n");
        }
    } else {
        if (cfg.provider == .proxy) {
            try stdout.print("  proxy_url     = {s}\n", .{cfg.proxy_url});
        } else if (cfg.provider == .ollama) {
            try stdout.print("  ollama_host   = {s}\n", .{cfg.ollama_host});
        } else {
            try stdout.writeAll("  api_key       = (not set)\n");
        }
    }

    // Show admin_key masked (only when set)
    if (cfg.admin_key) |k| {
        if (k.len > 8) {
            try stdout.print("  admin_key     = {s}...{s}\n", .{ k[0..4], k[k.len - 4 ..] });
        } else if (k.len > 0) {
            try stdout.writeAll("  admin_key     = ****\n");
        }
    }

    // Show config file path
    const config_path = config_mod.getConfigPath(allocator) catch {
        try stdout.writeAll("  config_file   = (unknown)\n\n");
        return;
    };
    defer allocator.free(config_path);
    try stdout.print("  config_file   = {s}\n\n", .{config_path});
}

fn resetConfig(allocator: std.mem.Allocator, stderr: anytype) !void {
    config_mod.reset(allocator) catch |err| {
        try stderr.print("Error resetting config: {}\n", .{err});
        return;
    };
    try stderr.writeAll("Config reset to defaults. Run `pls init` to reconfigure.\n");
}

/// Read from stdin if it's piped (not a terminal).
fn readStdinIfPiped(allocator: std.mem.Allocator) !?[]const u8 {
    const stdin_file = std.fs.File.stdin();
    if (stdin_file.isTty()) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const reader = stdin_file.deprecatedReader();
    while (true) {
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try buf.append(allocator, byte);
    }

    const result = std.mem.trim(u8, buf.items, " \t\r\n");
    if (result.len == 0) {
        buf.deinit(allocator);
        return null;
    }

    const owned = try allocator.dupe(u8, result);
    buf.deinit(allocator);
    return owned;
}

fn printUsage(out: anytype) !void {
    try out.writeAll(
        \\
        \\  pls - AI-powered command-line assistant
        \\
        \\  Usage:
        \\    pls <task>              Run a natural language task
        \\    pls init                Interactive setup wizard
        \\    pls history             Show recent task history
        \\    pls usage               Show proxy rate limit usage
        \\    pls config              Interactive config editor
        \\    pls config show         Show active configuration
        \\    pls config reset        Reset configuration to defaults
        \\
        \\  Options:
        \\    --confirm <mode>        Set confirmation mode: all, destructive, none
        \\    --yes, -y               Shorthand for --confirm=none
        \\    --provider <name>       Override LLM provider (proxy, anthropic, openai, gemini, ollama)
        \\    --model <name>          Override model name
        \\    --max-turns <n>         Maximum agent turns (default: 20)
        \\    --dry-run               Show commands without executing them
        \\    --version, -v           Show version
        \\    --help, -h              Show this help
        \\
        \\  Piping:
        \\    echo 'find large files' | pls
        \\
        \\  Examples:
        \\    pls 'stop all processes using port 1380'
        \\    pls 'find large files over 1GB'
        \\    pls --dry-run 'clean up docker containers'
        \\    pls --confirm=none 'kill process on port 3000'
        \\    pls --provider openai --model gpt-4o 'explain this error'
        \\
    );
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "writeHistoryEntries displays newest entry last" {
    const allocator = std.testing.allocator;

    const no_commands = [_][]const u8{};
    const entries = [_]history_mod.HistoryEntry{
        .{
            .timestamp = "2026-03-30T10:00:00Z",
            .cwd = "/tmp",
            .task = "newest",
            .commands = &no_commands,
        },
        .{
            .timestamp = "2026-03-30T09:00:00Z",
            .cwd = "/tmp",
            .task = "middle",
            .commands = &no_commands,
        },
        .{
            .timestamp = "2026-03-30T08:00:00Z",
            .cwd = "/tmp",
            .task = "oldest",
            .commands = &no_commands,
        },
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try writeHistoryEntries(allocator, output.writer(allocator), &entries, "");

    const expected =
        "\n" ++
        "[2026-03-30 08:00] /tmp\n" ++
        "  Task: oldest\n" ++
        "\n" ++
        "[2026-03-30 09:00] /tmp\n" ++
        "  Task: middle\n" ++
        "\n" ++
        "[2026-03-30 10:00] /tmp\n" ++
        "  Task: newest\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, output.items);
}
