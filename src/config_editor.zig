const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const tty = @import("tty.zig");

const readLine = tty.readLine;
const readLineMasked = tty.readLineMasked;

/// Run the interactive config editor.
pub fn runEditor(allocator: Allocator) !void {
    const out = std.fs.File.stderr().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    var cfg = config_mod.load(allocator) catch |err| {
        try out.print("Error loading config: {}\n", .{err});
        try out.writeAll("Run `pls init` to create a configuration first.\n");
        return;
    };
    defer cfg.deinit();

    while (true) {
        try displayMenu(&cfg, out);
        try out.writeAll("  Enter number to edit, or \x1b[1mq\x1b[0m to quit: ");

        const choice = try readLine(stdin);

        if (choice.len == 0 or
            std.mem.eql(u8, choice, "q") or
            std.mem.eql(u8, choice, "quit"))
        {
            try out.writeAll("\n");
            break;
        }

        const num = std.fmt.parseInt(usize, choice, 10) catch {
            try out.writeAll("  Invalid choice.\n\n");
            continue;
        };

        const changed = switch (num) {
            1 => try editProvider(&cfg, stdin, out),
            2 => try editConfirmMode(&cfg, stdin, out),
            3 => try editActiveModel(&cfg, stdin, out),
            4 => try editApiKey("Anthropic", &cfg, .anthropic, stdin, out),
            5 => try editApiKey("OpenAI", &cfg, .openai, stdin, out),
            6 => try editApiKey("Gemini", &cfg, .gemini, stdin, out),
            7 => try editFreeText("Ollama host URL", cfg.ollama_host, &cfg, .ollama_host, stdin, out),
            8 => try editFreeText("Anthropic model", cfg.anthropic_model, &cfg, .anthropic_model, stdin, out),
            9 => try editFreeText("OpenAI model", cfg.openai_model, &cfg, .openai_model, stdin, out),
            10 => try editFreeText("Gemini model", cfg.gemini_model, &cfg, .gemini_model, stdin, out),
            11 => try editFreeText("Ollama model", cfg.ollama_model, &cfg, .ollama_model, stdin, out),
            else => blk: {
                try out.writeAll("  Invalid choice.\n\n");
                break :blk false;
            },
        };

        if (changed) {
            config_mod.save(&cfg, allocator) catch |err| {
                try out.print("  \x1b[31mError saving config: {}\x1b[0m\n\n", .{err});
                continue;
            };
            try out.writeAll("  \x1b[32mSaved.\x1b[0m\n\n");
        }
    }
}

fn displayMenu(cfg: *const config_mod.Config, out: anytype) !void {
    try out.writeAll("\n  \x1b[1mpls configuration\x1b[0m\n");
    try out.writeAll("  \x1b[90m───────────────────────────────────────────────\x1b[0m\n");

    try out.print("   \x1b[1m1\x1b[0m) provider        = {s}\n", .{cfg.provider.toString()});
    try out.print("   \x1b[1m2\x1b[0m) confirm_mode    = {s}\n", .{cfg.confirm_mode.toString()});
    try out.print("   \x1b[1m3\x1b[0m) model           = {s}\n", .{cfg.getModel()});
    try out.print("   \x1b[1m4\x1b[0m) anthropic_key   = {s}\n", .{maskKey(cfg.anthropic_api_key)});
    try out.print("   \x1b[1m5\x1b[0m) openai_key      = {s}\n", .{maskKey(cfg.openai_api_key)});
    try out.print("   \x1b[1m6\x1b[0m) gemini_key      = {s}\n", .{maskKey(cfg.gemini_api_key)});
    try out.print("   \x1b[1m7\x1b[0m) ollama_host     = {s}\n", .{cfg.ollama_host});
    try out.print("   \x1b[1m8\x1b[0m) anthropic_model = {s}\n", .{cfg.anthropic_model});
    try out.print("   \x1b[1m9\x1b[0m) openai_model    = {s}\n", .{cfg.openai_model});
    try out.print("  \x1b[1m10\x1b[0m) gemini_model    = {s}\n", .{cfg.gemini_model});
    try out.print("  \x1b[1m11\x1b[0m) ollama_model    = {s}\n", .{cfg.ollama_model});
    try out.writeAll("\n");
}

fn maskKey(key: ?[]const u8) []const u8 {
    if (key) |k| {
        if (k.len > 8) {
            // We can't dynamically format here without allocation, so just
            // indicate it's set. The full masked view is in `config show`.
            return "(set)";
        } else if (k.len > 0) {
            return "(set)";
        } else {
            return "(empty)";
        }
    }
    return "(not set)";
}

fn editProvider(cfg: *config_mod.Config, stdin: anytype, out: anytype) !bool {
    try out.writeAll("\n  Select provider:\n");
    try out.print("    \x1b[1m1\x1b[0m) proxy (free tier){s}\n", .{if (cfg.provider == .proxy) " (current)" else ""});
    try out.print("    \x1b[1m2\x1b[0m) anthropic{s}\n", .{if (cfg.provider == .anthropic) " (current)" else ""});
    try out.print("    \x1b[1m3\x1b[0m) openai{s}\n", .{if (cfg.provider == .openai) " (current)" else ""});
    try out.print("    \x1b[1m4\x1b[0m) gemini{s}\n", .{if (cfg.provider == .gemini) " (current)" else ""});
    try out.print("    \x1b[1m5\x1b[0m) ollama{s}\n\n", .{if (cfg.provider == .ollama) " (current)" else ""});
    try out.writeAll("  Choice: ");

    const choice = try readLine(stdin);
    if (choice.len == 0) return false;

    const new_provider: config_mod.Provider = if (std.mem.eql(u8, choice, "1"))
        .proxy
    else if (std.mem.eql(u8, choice, "2"))
        .anthropic
    else if (std.mem.eql(u8, choice, "3"))
        .openai
    else if (std.mem.eql(u8, choice, "4"))
        .gemini
    else if (std.mem.eql(u8, choice, "5"))
        .ollama
    else {
        try out.writeAll("  Invalid choice.\n");
        return false;
    };

    if (new_provider == cfg.provider) {
        try out.writeAll("  No change.\n");
        return false;
    }

    cfg.provider = new_provider;
    return true;
}

fn editConfirmMode(cfg: *config_mod.Config, stdin: anytype, out: anytype) !bool {
    try out.writeAll("\n  Select confirmation mode:\n");
    try out.print("    \x1b[1m1\x1b[0m) all — confirm every command{s}\n", .{if (cfg.confirm_mode == .all) " (current)" else ""});
    try out.print("    \x1b[1m2\x1b[0m) destructive — only confirm dangerous commands{s}\n", .{if (cfg.confirm_mode == .destructive) " (current)" else ""});
    try out.print("    \x1b[1m3\x1b[0m) none — auto-execute everything{s}\n\n", .{if (cfg.confirm_mode == .none) " (current)" else ""});
    try out.writeAll("  Choice: ");

    const choice = try readLine(stdin);
    if (choice.len == 0) return false;

    const new_mode: config_mod.ConfirmMode = if (std.mem.eql(u8, choice, "1"))
        .all
    else if (std.mem.eql(u8, choice, "2"))
        .destructive
    else if (std.mem.eql(u8, choice, "3"))
        .none
    else {
        try out.writeAll("  Invalid choice.\n");
        return false;
    };

    if (new_mode == cfg.confirm_mode) {
        try out.writeAll("  No change.\n");
        return false;
    }

    cfg.confirm_mode = new_mode;
    return true;
}

fn editActiveModel(cfg: *config_mod.Config, stdin: anytype, out: anytype) !bool {
    return switch (cfg.provider) {
        .proxy => editModelMenu(cfg, .proxy_model, "proxy", &[_][]const u8{
            "gemini-3-flash-preview",
            "gemini-2.5-flash-lite",
        }, cfg.proxy_model, stdin, out),
        .anthropic => editModelMenu(cfg, .anthropic_model, "anthropic", &[_][]const u8{
            "claude-sonnet-4-5-20250514",
            "claude-opus-4-5-20250514",
            "claude-haiku-3-5-20241022",
        }, cfg.anthropic_model, stdin, out),
        .openai => editModelMenu(cfg, .openai_model, "openai", &[_][]const u8{
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4-turbo",
        }, cfg.openai_model, stdin, out),
        .gemini => editModelMenu(cfg, .gemini_model, "gemini", &[_][]const u8{
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
        }, cfg.gemini_model, stdin, out),
        .ollama => editModelMenu(cfg, .ollama_model, "ollama", &[_][]const u8{
            "llama3.1",
            "llama3.2",
            "mistral",
            "qwen2.5",
        }, cfg.ollama_model, stdin, out),
    };
}

const StringField = enum {
    proxy_model,
    anthropic_model,
    openai_model,
    gemini_model,
    ollama_model,
    ollama_host,
};

fn editModelMenu(
    cfg: *config_mod.Config,
    comptime field: StringField,
    provider_name: []const u8,
    presets: []const []const u8,
    current: []const u8,
    stdin: anytype,
    out: anytype,
) !bool {
    try out.print("\n  Select model for {s}:\n", .{provider_name});

    for (presets, 0..) |preset, i| {
        const is_current = std.mem.eql(u8, preset, current);
        try out.print("    \x1b[1m{d}\x1b[0m) {s}{s}\n", .{
            i + 1,
            preset,
            if (is_current) " (current)" else "",
        });
    }
    try out.print("    \x1b[1m{d}\x1b[0m) Custom\n\n", .{presets.len + 1});
    try out.writeAll("  Choice: ");

    const choice = try readLine(stdin);
    if (choice.len == 0) return false;

    const num = std.fmt.parseInt(usize, choice, 10) catch {
        try out.writeAll("  Invalid choice.\n");
        return false;
    };

    if (num >= 1 and num <= presets.len) {
        const selected = presets[num - 1];
        if (std.mem.eql(u8, selected, current)) {
            try out.writeAll("  No change.\n");
            return false;
        }
        setStringField(cfg, field, try cfg.ownString(selected));
        return true;
    } else if (num == presets.len + 1) {
        try out.writeAll("  Enter model name: ");
        const custom = try readLine(stdin);
        if (custom.len == 0) return false;
        if (std.mem.eql(u8, custom, current)) {
            try out.writeAll("  No change.\n");
            return false;
        }
        setStringField(cfg, field, try cfg.ownString(custom));
        return true;
    } else {
        try out.writeAll("  Invalid choice.\n");
        return false;
    }
}

fn editApiKey(
    provider_name: []const u8,
    cfg: *config_mod.Config,
    provider: config_mod.Provider,
    stdin: anytype,
    out: anytype,
) !bool {
    try out.print("\n  Enter {s} API key (leave blank to keep current): ", .{provider_name});
    const key = try readLineMasked(stdin);

    if (key.len == 0) return false;

    const owned = try cfg.ownString(key);
    switch (provider) {
        .proxy => {}, // Proxy doesn't use API keys
        .anthropic => cfg.anthropic_api_key = owned,
        .openai => cfg.openai_api_key = owned,
        .gemini => cfg.gemini_api_key = owned,
        .ollama => {}, // Ollama doesn't use API keys
    }
    return true;
}

fn editFreeText(
    label: []const u8,
    current: []const u8,
    cfg: *config_mod.Config,
    comptime field: StringField,
    stdin: anytype,
    out: anytype,
) !bool {
    try out.print("\n  Enter {s} [{s}]: ", .{ label, current });
    const value = try readLine(stdin);

    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, current)) {
        try out.writeAll("  No change.\n");
        return false;
    }

    setStringField(cfg, field, try cfg.ownString(value));
    return true;
}

fn setStringField(cfg: *config_mod.Config, comptime field: StringField, value: []const u8) void {
    switch (field) {
        .proxy_model => cfg.proxy_model = value,
        .anthropic_model => cfg.anthropic_model = value,
        .openai_model => cfg.openai_model = value,
        .gemini_model => cfg.gemini_model = value,
        .ollama_model => cfg.ollama_model = value,
        .ollama_host => cfg.ollama_host = value,
    }
}
