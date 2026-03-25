const std = @import("std");
const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const init_mod = @import("init.zig");
const config_editor = @import("config_editor.zig");

const VERSION = "0.2.0";

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
        } else if (std.mem.eql(u8, arg, "config") and i + 1 < args.len and std.mem.eql(u8, args[i + 1], "show")) {
            try showConfig(allocator, stdout, stderr);
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

    // Run the agent
    var agent = try agent_mod.Agent.init(allocator, &cfg, .{
        .confirm_mode = confirm_mode,
        .dry_run = dry_run,
        .max_turns = max_turns,
    });
    defer agent.deinit();

    agent.run(task) catch |err| {
        try stderr.print("\nError: {}\n", .{err});
        switch (err) {
            error.NoApiKey => try stderr.writeAll("Run `pls init` to configure your API key.\n"),
            error.HttpError => try stderr.writeAll("Failed to connect to the LLM API. Check your network.\n"),
            error.ApiError => try stderr.writeAll("The LLM API returned an error. Check your API key and model.\n"),
            else => {},
        }
    };
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

    // Show config file path
    const config_path = config_mod.getConfigPath(allocator) catch {
        try stdout.writeAll("  config_file   = (unknown)\n\n");
        return;
    };
    defer allocator.free(config_path);
    try stdout.print("  config_file   = {s}\n\n", .{config_path});
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
        \\    pls config              Interactive config editor
        \\    pls config show         Show active configuration
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
