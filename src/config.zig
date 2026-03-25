const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ConfirmMode = enum {
    all,
    destructive,
    none,

    pub fn fromString(s: []const u8) ?ConfirmMode {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "destructive")) return .destructive;
        if (std.mem.eql(u8, s, "none")) return .none;
        return null;
    }

    pub fn toString(self: ConfirmMode) []const u8 {
        return switch (self) {
            .all => "all",
            .destructive => "destructive",
            .none => "none",
        };
    }
};

pub const Provider = enum {
    proxy,
    anthropic,
    openai,
    gemini,
    ollama,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "proxy")) return .proxy;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        return null;
    }

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .proxy => "proxy",
            .anthropic => "anthropic",
            .openai => "openai",
            .gemini => "gemini",
            .ollama => "ollama",
        };
    }

    /// Returns true if this provider requires an API key.
    pub fn requiresApiKey(self: Provider) bool {
        return switch (self) {
            .proxy, .ollama => false,
            .anthropic, .openai, .gemini => true,
        };
    }
};

pub const DEFAULT_PROXY_URL = "https://pls-proxy.seokjun.kim";
pub const DEFAULT_PROXY_MODEL = "gemini-3-flash-preview";

pub const Config = struct {
    provider: Provider = .proxy,
    confirm_mode: ConfirmMode = .all,

    proxy_url: []const u8 = DEFAULT_PROXY_URL,
    proxy_model: []const u8 = DEFAULT_PROXY_MODEL,

    anthropic_api_key: ?[]const u8 = null,
    anthropic_model: []const u8 = "claude-sonnet-4-5-20250514",

    openai_api_key: ?[]const u8 = null,
    openai_model: []const u8 = "gpt-4o",

    gemini_api_key: ?[]const u8 = null,
    gemini_model: []const u8 = "gemini-2.5-flash",

    ollama_host: []const u8 = "http://localhost:11434",
    ollama_model: []const u8 = "llama3.1",

    allocator: Allocator,

    /// Strings allocated by config loading that need to be freed.
    owned_strings: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: Allocator) Config {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
    }

    /// Get the active API key for the current provider.
    pub fn getApiKey(self: *const Config) ?[]const u8 {
        return switch (self.provider) {
            .proxy => null,
            .anthropic => self.anthropic_api_key,
            .openai => self.openai_api_key,
            .gemini => self.gemini_api_key,
            .ollama => null,
        };
    }

    /// Get the active model for the current provider.
    pub fn getModel(self: *const Config) []const u8 {
        return switch (self.provider) {
            .proxy => self.proxy_model,
            .anthropic => self.anthropic_model,
            .openai => self.openai_model,
            .gemini => self.gemini_model,
            .ollama => self.ollama_model,
        };
    }

    /// Get the base URL for the current provider.
    pub fn getBaseUrl(self: *const Config) []const u8 {
        return switch (self.provider) {
            .proxy => self.proxy_url,
            .anthropic => "https://api.anthropic.com",
            .openai => "https://api.openai.com",
            .gemini => "https://generativelanguage.googleapis.com",
            .ollama => self.ollama_host,
        };
    }

    pub fn ownString(self: *Config, s: []const u8) ![]const u8 {
        const duped = try self.allocator.dupe(u8, s);
        try self.owned_strings.append(self.allocator, duped);
        return duped;
    }

    fn setField(self: *Config, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "provider")) {
            if (Provider.fromString(value)) |p| {
                self.provider = p;
            }
        } else if (std.mem.eql(u8, key, "confirm_mode")) {
            if (ConfirmMode.fromString(value)) |m| {
                self.confirm_mode = m;
            }
        } else if (std.mem.eql(u8, key, "proxy_url")) {
            self.proxy_url = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "proxy_model")) {
            self.proxy_model = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "anthropic_api_key")) {
            self.anthropic_api_key = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "anthropic_model")) {
            self.anthropic_model = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "openai_api_key")) {
            self.openai_api_key = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "openai_model")) {
            self.openai_model = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "gemini_api_key")) {
            self.gemini_api_key = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "gemini_model")) {
            self.gemini_model = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "ollama_host")) {
            self.ollama_host = try self.ownString(value);
        } else if (std.mem.eql(u8, key, "ollama_model")) {
            self.ollama_model = try self.ownString(value);
        }
    }
};

/// Get the config directory path: ~/.config/pls/
pub fn getConfigDir(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/pls", .{xdg});
    }
    if (std.posix.getenv("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/pls", .{home});
    }
    return error.NoHomeDir;
}

/// Get the config file path: ~/.config/pls/config.toml
pub fn getConfigPath(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/pls/config.toml", .{xdg});
    }
    if (std.posix.getenv("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/pls/config.toml", .{home});
    }
    return error.NoHomeDir;
}

/// Load config from file, with env var overrides.
pub fn load(allocator: Allocator) !Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();

    // Try to load from file
    const config_path = getConfigPath(allocator) catch |err| {
        if (err == error.NoHomeDir) {
            applyEnvOverrides(&cfg) catch {};
            return cfg;
        }
        return err;
    };
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try applyEnvOverrides(&cfg);
            return cfg;
        }
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try applyEnvOverrides(&cfg);
        return cfg;
    };
    defer allocator.free(content);

    try parseTOML(&cfg, content);
    try applyEnvOverrides(&cfg);

    return cfg;
}

/// Parse flat TOML: key = "value" or key = value
fn parseTOML(cfg: *Config, content: []const u8) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        try cfg.setField(key, value);
    }
}

/// Override config with environment variables.
fn applyEnvOverrides(cfg: *Config) !void {
    if (std.posix.getenv("DO_PROVIDER") orelse std.posix.getenv("PLS_PROVIDER")) |v| {
        if (Provider.fromString(v)) |p| {
            cfg.provider = p;
        }
    }
    if (std.posix.getenv("PLS_CONFIRM")) |v| {
        if (ConfirmMode.fromString(v)) |m| {
            cfg.confirm_mode = m;
        }
    }
    if (std.posix.getenv("PLS_PROXY_URL")) |v| {
        cfg.proxy_url = try cfg.ownString(v);
    }
    if (std.posix.getenv("PLS_PROXY_MODEL")) |v| {
        cfg.proxy_model = try cfg.ownString(v);
    }
    if (std.posix.getenv("ANTHROPIC_API_KEY")) |v| {
        cfg.anthropic_api_key = try cfg.ownString(v);
    }
    if (std.posix.getenv("OPENAI_API_KEY")) |v| {
        cfg.openai_api_key = try cfg.ownString(v);
    }
    if (std.posix.getenv("GEMINI_API_KEY")) |v| {
        cfg.gemini_api_key = try cfg.ownString(v);
    }
    if (std.posix.getenv("OLLAMA_HOST")) |v| {
        cfg.ollama_host = try cfg.ownString(v);
    }
    if (std.posix.getenv("OLLAMA_MODEL")) |v| {
        cfg.ollama_model = try cfg.ownString(v);
    }
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "ConfirmMode.fromString returns correct variants" {
    try std.testing.expectEqual(ConfirmMode.all, ConfirmMode.fromString("all").?);
    try std.testing.expectEqual(ConfirmMode.destructive, ConfirmMode.fromString("destructive").?);
    try std.testing.expectEqual(ConfirmMode.none, ConfirmMode.fromString("none").?);
}

test "ConfirmMode.fromString returns null for unknown" {
    try std.testing.expect(ConfirmMode.fromString("") == null);
    try std.testing.expect(ConfirmMode.fromString("ALL") == null);
    try std.testing.expect(ConfirmMode.fromString("foo") == null);
}

test "ConfirmMode round-trip" {
    inline for (.{ ConfirmMode.all, ConfirmMode.destructive, ConfirmMode.none }) |mode| {
        try std.testing.expectEqual(mode, ConfirmMode.fromString(mode.toString()).?);
    }
}

test "Provider.fromString returns correct variants" {
    try std.testing.expectEqual(Provider.proxy, Provider.fromString("proxy").?);
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("anthropic").?);
    try std.testing.expectEqual(Provider.openai, Provider.fromString("openai").?);
    try std.testing.expectEqual(Provider.gemini, Provider.fromString("gemini").?);
    try std.testing.expectEqual(Provider.ollama, Provider.fromString("ollama").?);
}

test "Provider.fromString returns null for unknown" {
    try std.testing.expect(Provider.fromString("") == null);
    try std.testing.expect(Provider.fromString("claude") == null);
    try std.testing.expect(Provider.fromString("OPENAI") == null);
}

test "Provider round-trip" {
    inline for (.{ Provider.proxy, Provider.anthropic, Provider.openai, Provider.gemini, Provider.ollama }) |p| {
        try std.testing.expectEqual(p, Provider.fromString(p.toString()).?);
    }
}

test "Config defaults" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(Provider.proxy, cfg.provider);
    try std.testing.expectEqual(ConfirmMode.all, cfg.confirm_mode);
    try std.testing.expectEqualStrings(DEFAULT_PROXY_URL, cfg.proxy_url);
    try std.testing.expectEqualStrings(DEFAULT_PROXY_MODEL, cfg.proxy_model);
    try std.testing.expect(cfg.anthropic_api_key == null);
    try std.testing.expect(cfg.openai_api_key == null);
    try std.testing.expect(cfg.gemini_api_key == null);
    try std.testing.expectEqualStrings("claude-sonnet-4-5-20250514", cfg.anthropic_model);
    try std.testing.expectEqualStrings("gpt-4o", cfg.openai_model);
    try std.testing.expectEqualStrings("gemini-2.5-flash", cfg.gemini_model);
    try std.testing.expectEqualStrings("llama3.1", cfg.ollama_model);
    try std.testing.expectEqualStrings("http://localhost:11434", cfg.ollama_host);
}

test "Config.getApiKey dispatches by provider" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    cfg.anthropic_api_key = try cfg.ownString("ant-key");
    cfg.openai_api_key = try cfg.ownString("oai-key");
    cfg.gemini_api_key = try cfg.ownString("gem-key");

    cfg.provider = .anthropic;
    try std.testing.expectEqualStrings("ant-key", cfg.getApiKey().?);

    cfg.provider = .openai;
    try std.testing.expectEqualStrings("oai-key", cfg.getApiKey().?);

    cfg.provider = .gemini;
    try std.testing.expectEqualStrings("gem-key", cfg.getApiKey().?);

    cfg.provider = .ollama;
    try std.testing.expect(cfg.getApiKey() == null);

    cfg.provider = .proxy;
    try std.testing.expect(cfg.getApiKey() == null);
}

test "Config.getModel dispatches by provider" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    cfg.provider = .proxy;
    try std.testing.expectEqualStrings(DEFAULT_PROXY_MODEL, cfg.getModel());

    cfg.provider = .anthropic;
    try std.testing.expectEqualStrings("claude-sonnet-4-5-20250514", cfg.getModel());

    cfg.provider = .openai;
    try std.testing.expectEqualStrings("gpt-4o", cfg.getModel());

    cfg.provider = .gemini;
    try std.testing.expectEqualStrings("gemini-2.5-flash", cfg.getModel());

    cfg.provider = .ollama;
    try std.testing.expectEqualStrings("llama3.1", cfg.getModel());
}

test "parseTOML basic key-value pairs" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg,
        \\provider = "openai"
        \\openai_api_key = "sk-test-123"
        \\openai_model = "gpt-4-turbo"
        \\confirm_mode = "destructive"
    );

    try std.testing.expectEqual(Provider.openai, cfg.provider);
    try std.testing.expectEqualStrings("sk-test-123", cfg.openai_api_key.?);
    try std.testing.expectEqualStrings("gpt-4-turbo", cfg.openai_model);
    try std.testing.expectEqual(ConfirmMode.destructive, cfg.confirm_mode);
}

test "parseTOML unquoted values" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg, "provider = gemini\n");

    try std.testing.expectEqual(Provider.gemini, cfg.provider);
}

test "parseTOML skips comments and blank lines" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg,
        \\# This is a comment
        \\
        \\  # Indented comment
        \\provider = "ollama"
        \\
        \\# Another comment
        \\ollama_model = "mistral"
    );

    try std.testing.expectEqual(Provider.ollama, cfg.provider);
    try std.testing.expectEqualStrings("mistral", cfg.ollama_model);
}

test "parseTOML ignores unknown keys" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg,
        \\unknown_key = "value"
        \\provider = "anthropic"
        \\future_setting = "42"
    );

    try std.testing.expectEqual(Provider.anthropic, cfg.provider);
}

test "parseTOML handles all fields" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg,
        \\provider = "gemini"
        \\confirm_mode = "none"
        \\anthropic_api_key = "ant-k"
        \\anthropic_model = "claude-3"
        \\openai_api_key = "oai-k"
        \\openai_model = "gpt-5"
        \\gemini_api_key = "gem-k"
        \\gemini_model = "gemini-3"
        \\ollama_host = "http://remote:11434"
        \\ollama_model = "qwen"
    );

    try std.testing.expectEqual(Provider.gemini, cfg.provider);
    try std.testing.expectEqual(ConfirmMode.none, cfg.confirm_mode);
    try std.testing.expectEqualStrings("ant-k", cfg.anthropic_api_key.?);
    try std.testing.expectEqualStrings("claude-3", cfg.anthropic_model);
    try std.testing.expectEqualStrings("oai-k", cfg.openai_api_key.?);
    try std.testing.expectEqualStrings("gpt-5", cfg.openai_model);
    try std.testing.expectEqualStrings("gem-k", cfg.gemini_api_key.?);
    try std.testing.expectEqualStrings("gemini-3", cfg.gemini_model);
    try std.testing.expectEqualStrings("http://remote:11434", cfg.ollama_host);
    try std.testing.expectEqualStrings("qwen", cfg.ollama_model);
}

test "parseTOML handles extra whitespace" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try parseTOML(&cfg, "  provider  =  \"openai\"  \n");

    try std.testing.expectEqual(Provider.openai, cfg.provider);
}

test "parseTOML handles line without equals sign" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    // Should not crash, just skip the line
    try parseTOML(&cfg, "invalid line without equals\nprovider = \"anthropic\"\n");

    try std.testing.expectEqual(Provider.anthropic, cfg.provider);
}

/// Write config to file.
pub fn save(cfg: *const Config, allocator: Allocator) !void {
    const dir_path = try getConfigDir(allocator);
    defer allocator.free(dir_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    const writer = file.deprecatedWriter();

    try writer.print("# pls CLI configuration\n", .{});
    try writer.print("# Generated by `pls init`\n\n", .{});
    try writer.print("provider = \"{s}\"\n", .{cfg.provider.toString()});
    try writer.print("confirm_mode = \"{s}\"\n\n", .{cfg.confirm_mode.toString()});

    // Proxy settings (only write if non-default)
    if (!std.mem.eql(u8, cfg.proxy_url, DEFAULT_PROXY_URL)) {
        try writer.print("proxy_url = \"{s}\"\n", .{cfg.proxy_url});
    }
    if (!std.mem.eql(u8, cfg.proxy_model, DEFAULT_PROXY_MODEL)) {
        try writer.print("proxy_model = \"{s}\"\n", .{cfg.proxy_model});
    }

    if (cfg.anthropic_api_key) |key| {
        try writer.print("anthropic_api_key = \"{s}\"\n", .{key});
    }
    try writer.print("anthropic_model = \"{s}\"\n\n", .{cfg.anthropic_model});

    if (cfg.openai_api_key) |key| {
        try writer.print("openai_api_key = \"{s}\"\n", .{key});
    }
    try writer.print("openai_model = \"{s}\"\n\n", .{cfg.openai_model});

    // Gemini
    if (cfg.gemini_api_key) |key| {
        try writer.print("gemini_api_key = \"{s}\"\n", .{key});
    }
    try writer.print("gemini_model = \"{s}\"\n\n", .{cfg.gemini_model});

    try writer.print("ollama_host = \"{s}\"\n", .{cfg.ollama_host});
    try writer.print("ollama_model = \"{s}\"\n", .{cfg.ollama_model});
}
