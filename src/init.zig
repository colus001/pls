const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const tty = @import("tty.zig");

const readLine = tty.readLine;
const readLineMasked = tty.readLineMasked;

/// Run the interactive setup wizard.
pub fn runSetup(allocator: Allocator) !void {
    const out = std.fs.File.stderr().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    try out.writeAll("\n");
    try out.writeAll("  Welcome to \x1b[1mpls\x1b[0m! Let's get you set up.\n\n");

    // Select provider
    try out.writeAll("  Select your LLM provider:\n");
    try out.writeAll("    \x1b[1m1\x1b[0m) Free tier - no API key needed (default)\n");
    try out.writeAll("    \x1b[1m2\x1b[0m) Anthropic (Claude)\n");
    try out.writeAll("    \x1b[1m3\x1b[0m) OpenAI (GPT)\n");
    try out.writeAll("    \x1b[1m4\x1b[0m) Google Gemini\n");
    try out.writeAll("    \x1b[1m5\x1b[0m) Ollama (local)\n\n");
    try out.writeAll("  Choice [1]: ");

    const provider_choice = try readLine(stdin);
    const prov: config_mod.Provider = if (provider_choice.len == 0 or std.mem.eql(u8, provider_choice, "1"))
        .proxy
    else if (std.mem.eql(u8, provider_choice, "2"))
        .anthropic
    else if (std.mem.eql(u8, provider_choice, "3"))
        .openai
    else if (std.mem.eql(u8, provider_choice, "4"))
        .gemini
    else if (std.mem.eql(u8, provider_choice, "5"))
        .ollama
    else blk: {
        try out.writeAll("  Invalid choice, defaulting to free tier.\n");
        break :blk .proxy;
    };

    var cfg = config_mod.Config.init(allocator);
    cfg.provider = prov;

    try out.writeAll("\n");

    switch (prov) {
        .proxy => {
            try out.writeAll("  Using the free proxy tier. No API key needed.\n");
            try out.writeAll("  You can switch to your own API key anytime with `pls config`.\n");
        },
        .anthropic => {
            // API key
            try out.writeAll("  Enter your Anthropic API key: ");
            const key = try readLineMasked(stdin);
            if (key.len > 0) {
                cfg.anthropic_api_key = try cfg.ownString(key);
            }

            // Model
            try out.writeAll("\n  Select a model:\n");
            try out.writeAll("    \x1b[1m1\x1b[0m) claude-sonnet-4-5-20250514 (recommended)\n");
            try out.writeAll("    \x1b[1m2\x1b[0m) claude-opus-4-5-20250514\n");
            try out.writeAll("    \x1b[1m3\x1b[0m) claude-haiku-3-5-20241022\n");
            try out.writeAll("    \x1b[1m4\x1b[0m) Custom\n\n");
            try out.writeAll("  Choice [1]: ");
            const model_choice = try readLine(stdin);

            if (model_choice.len == 0 or std.mem.eql(u8, model_choice, "1")) {
                // default
            } else if (std.mem.eql(u8, model_choice, "2")) {
                cfg.anthropic_model = try cfg.ownString("claude-opus-4-5-20250514");
            } else if (std.mem.eql(u8, model_choice, "3")) {
                cfg.anthropic_model = try cfg.ownString("claude-haiku-3-5-20241022");
            } else if (std.mem.eql(u8, model_choice, "4")) {
                try out.writeAll("  Enter model name: ");
                const custom = try readLine(stdin);
                if (custom.len > 0) {
                    cfg.anthropic_model = try cfg.ownString(custom);
                }
            }
        },
        .openai => {
            // API key
            try out.writeAll("  Enter your OpenAI API key: ");
            const key = try readLineMasked(stdin);
            if (key.len > 0) {
                cfg.openai_api_key = try cfg.ownString(key);
            }

            // Model
            try out.writeAll("\n  Select a model:\n");
            try out.writeAll("    \x1b[1m1\x1b[0m) gpt-4o (recommended)\n");
            try out.writeAll("    \x1b[1m2\x1b[0m) gpt-4o-mini\n");
            try out.writeAll("    \x1b[1m3\x1b[0m) gpt-4-turbo\n");
            try out.writeAll("    \x1b[1m4\x1b[0m) Custom\n\n");
            try out.writeAll("  Choice [1]: ");
            const model_choice = try readLine(stdin);

            if (model_choice.len == 0 or std.mem.eql(u8, model_choice, "1")) {
                // default
            } else if (std.mem.eql(u8, model_choice, "2")) {
                cfg.openai_model = try cfg.ownString("gpt-4o-mini");
            } else if (std.mem.eql(u8, model_choice, "3")) {
                cfg.openai_model = try cfg.ownString("gpt-4-turbo");
            } else if (std.mem.eql(u8, model_choice, "4")) {
                try out.writeAll("  Enter model name: ");
                const custom = try readLine(stdin);
                if (custom.len > 0) {
                    cfg.openai_model = try cfg.ownString(custom);
                }
            }
        },
        .gemini => {
            // API key
            try out.writeAll("  Enter your Gemini API key: ");
            const key = try readLineMasked(stdin);
            if (key.len > 0) {
                cfg.gemini_api_key = try cfg.ownString(key);
            }

            // Model
            try out.writeAll("\n  Select a model:\n");
            try out.writeAll("    \x1b[1m1\x1b[0m) gemini-2.5-flash (recommended)\n");
            try out.writeAll("    \x1b[1m2\x1b[0m) gemini-2.5-pro\n");
            try out.writeAll("    \x1b[1m3\x1b[0m) gemini-2.0-flash\n");
            try out.writeAll("    \x1b[1m4\x1b[0m) Custom\n\n");
            try out.writeAll("  Choice [1]: ");
            const model_choice = try readLine(stdin);

            if (model_choice.len == 0 or std.mem.eql(u8, model_choice, "1")) {
                // default
            } else if (std.mem.eql(u8, model_choice, "2")) {
                cfg.gemini_model = try cfg.ownString("gemini-2.5-pro");
            } else if (std.mem.eql(u8, model_choice, "3")) {
                cfg.gemini_model = try cfg.ownString("gemini-2.0-flash");
            } else if (std.mem.eql(u8, model_choice, "4")) {
                try out.writeAll("  Enter model name: ");
                const custom = try readLine(stdin);
                if (custom.len > 0) {
                    cfg.gemini_model = try cfg.ownString(custom);
                }
            }
        },
        .ollama => {
            // Host
            try out.writeAll("  Ollama host URL [http://localhost:11434]: ");
            const host = try readLine(stdin);
            if (host.len > 0) {
                cfg.ollama_host = try cfg.ownString(host);
            }

            // Model
            try out.writeAll("\n  Select a model:\n");
            try out.writeAll("    \x1b[1m1\x1b[0m) llama3.1 (recommended)\n");
            try out.writeAll("    \x1b[1m2\x1b[0m) llama3.2\n");
            try out.writeAll("    \x1b[1m3\x1b[0m) mistral\n");
            try out.writeAll("    \x1b[1m4\x1b[0m) qwen2.5\n");
            try out.writeAll("    \x1b[1m5\x1b[0m) Custom\n\n");
            try out.writeAll("  Choice [1]: ");
            const model_choice = try readLine(stdin);

            if (model_choice.len == 0 or std.mem.eql(u8, model_choice, "1")) {
                // default
            } else if (std.mem.eql(u8, model_choice, "2")) {
                cfg.ollama_model = try cfg.ownString("llama3.2");
            } else if (std.mem.eql(u8, model_choice, "3")) {
                cfg.ollama_model = try cfg.ownString("mistral");
            } else if (std.mem.eql(u8, model_choice, "4")) {
                cfg.ollama_model = try cfg.ownString("qwen2.5");
            } else if (std.mem.eql(u8, model_choice, "5")) {
                try out.writeAll("  Enter model name: ");
                const custom = try readLine(stdin);
                if (custom.len > 0) {
                    cfg.ollama_model = try cfg.ownString(custom);
                }
            }
        },
    }

    // Confirm mode
    try out.writeAll("\n  Command confirmation mode:\n");
    try out.writeAll("    \x1b[1m1\x1b[0m) Confirm every command before running (recommended)\n");
    try out.writeAll("    \x1b[1m2\x1b[0m) Confirm only destructive commands (kill, rm, etc.)\n");
    try out.writeAll("    \x1b[1m3\x1b[0m) No confirmation (auto-execute everything)\n\n");
    try out.writeAll("  Choice [1]: ");

    const confirm_choice = try readLine(stdin);
    if (confirm_choice.len == 0 or std.mem.eql(u8, confirm_choice, "1")) {
        cfg.confirm_mode = .all;
    } else if (std.mem.eql(u8, confirm_choice, "2")) {
        cfg.confirm_mode = .destructive;
    } else if (std.mem.eql(u8, confirm_choice, "3")) {
        cfg.confirm_mode = .none;
    } else {
        try out.writeAll("  Invalid choice, defaulting to confirm all.\n");
        cfg.confirm_mode = .all;
    }

    // Show config path and confirm save
    const config_path = try config_mod.getConfigPath(allocator);
    defer allocator.free(config_path);

    try out.print("\n  Config will be saved to: \x1b[1m{s}\x1b[0m\n", .{config_path});
    try out.writeAll("  Save? [Y/n]: ");

    const save_choice = try readLine(stdin);
    if (save_choice.len == 0 or
        std.ascii.eqlIgnoreCase(save_choice, "y") or
        std.ascii.eqlIgnoreCase(save_choice, "yes"))
    {
        try config_mod.save(&cfg, allocator);
        try out.writeAll("\n  \x1b[32mConfig saved!\x1b[0m Run \x1b[1mpls 'hello'\x1b[0m to test it.\n\n");
    } else {
        try out.writeAll("\n  Setup cancelled.\n\n");
    }
}
