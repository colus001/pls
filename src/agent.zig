const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const provider = @import("llm/provider.zig");
const anthropic = @import("llm/anthropic.zig");
const openai = @import("llm/openai.zig");
const gemini = @import("llm/gemini.zig");
const proxy = @import("llm/proxy.zig");
const ollama = @import("llm/ollama.zig");
const shell = @import("tools/shell.zig");
const confirm = @import("tools/confirm.zig");

const SYSTEM_PROMPT_BASE =
    \\You are `pls`, a command-line assistant that helps users accomplish tasks by executing shell commands.
    \\
    \\You have access to the following tools:
    \\
    \\1. `run_shell` - Execute a shell command on the user's machine. Use this to accomplish the user's task.
    \\   Arguments: {"command": "the shell command to run"}
    \\
    \\2. `ask_user` - Ask the user a clarifying question when their request is ambiguous.
    \\   Use ONLY for clarification, NEVER for confirming command execution (that is handled automatically).
    \\   Arguments: {"question": "the question", "options": "[\"option A\", \"option B\"]", "recommended": "0"}
    \\   - options: a JSON array of option strings for the user to choose from.
    \\   - recommended: optional 0-based index of the recommended option.
    \\   The user can pick a numbered option or type a custom answer.
    \\
    \\Guidelines:
    \\- If the user's request is ambiguous, use `ask_user` to clarify before doing anything.
    \\- Before running commands, briefly state your plan so the user can see your thinking.
    \\- IMPORTANT: Emit ALL commands in a SINGLE response. Never split commands across
    \\  multiple responses just to observe output between them.
    \\  - Independent steps: use separate `run_shell` calls, one per command.
    \\    Example: deleting 3 files → 3 separate `run_shell` calls in one response.
    \\  - Dependent steps (where a later step needs an earlier step's output): use ONE
    \\    `run_shell` call with a multi-line shell script using variables.
    \\    Example: finding and killing a process →
    \\      `run_shell("PID=$(lsof -t -i :3000)\nkill $PID")`
    \\  - Only send a follow-up response if a command fails or produces unexpected output
    \\    that requires a different approach.
    \\- Prefer safe, reversible approaches when possible.
    \\- Keep your text responses short and clear.
    \\- If a command fails, try to diagnose the issue and suggest alternatives.
    \\- If the user declines to execute, stop immediately. Do not suggest alternatives,
    \\  ask follow-up questions, or take any further action.
    \\- Use commands appropriate for the user's OS and shell shown in the environment below.
    \\- Respond in the same language the user uses.
;

/// Build the full system prompt by appending runtime environment context.
fn buildSystemPrompt(allocator: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Static base prompt
    try w.writeAll(SYSTEM_PROMPT_BASE);

    // Environment context
    try w.writeAll("\n\nEnvironment:\n");

    // OS and architecture from uname
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    const machine = std.mem.sliceTo(&uts.machine, 0);
    const nodename = std.mem.sliceTo(&uts.nodename, 0);

    try w.print("- OS: {s} {s} ({s})\n", .{ sysname, release, machine });
    try w.print("- Hostname: {s}\n", .{nodename});

    // User
    if (std.posix.getenv("USER")) |user| {
        try w.print("- User: {s}\n", .{user});
    }

    // Shell
    if (std.posix.getenv("SHELL")) |user_shell| {
        try w.print("- Shell: {s}\n", .{user_shell});
    }

    // Current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.posix.getcwd(&cwd_buf)) |cwd| {
        try w.print("- Working directory: {s}\n", .{cwd});
    } else |_| {
        if (std.posix.getenv("PWD")) |pwd| {
            try w.print("- Working directory: {s}\n", .{pwd});
        }
    }

    // Home directory
    if (std.posix.getenv("HOME")) |home| {
        try w.print("- Home: {s}\n", .{home});
    }

    return buf.toOwnedSlice(allocator);
}

const TOOLS = [_]provider.Tool{
    .{
        .name = "run_shell",
        .description = "Execute a shell command on the user's machine and return its output.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "command", .type = "string", .description = "The shell command or multi-line script to execute" },
        },
        .required = &[_][]const u8{"command"},
    },
    .{
        .name = "ask_user",
        .description = "Ask the user a clarifying question when their request is ambiguous. Do NOT use this for confirming command execution.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "question", .type = "string", .description = "The question to ask" },
            .{ .name = "options", .type = "string", .description = "A JSON array of option strings, e.g. [\"option A\", \"option B\"]" },
            .{ .name = "recommended", .type = "string", .description = "0-based index of the recommended option (optional)" },
        },
        .required = &[_][]const u8{ "question", "options" },
    },
};

/// A terminal spinner that shows a rotating animation while waiting for LLM responses.
const Spinner = struct {
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    const FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const INTERVAL_NS = 80 * std.time.ns_per_ms;

    pub fn init() Spinner {
        return .{
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    pub fn start(self: *Spinner) void {
        self.running.store(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    pub fn stop(self: *Spinner) void {
        self.running.store(false, .seq_cst);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(self: *Spinner) void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        var i: usize = 0;
        while (self.running.load(.seq_cst)) {
            stderr.print("\r\x1b[90m{s} Thinking...\x1b[0m", .{FRAMES[i % FRAMES.len]}) catch {};
            i +%= 1;
            std.Thread.sleep(INTERVAL_NS);
        }
        // Clear the spinner line
        stderr.writeAll("\r\x1b[K") catch {};
    }
};

pub const AgentOptions = struct {
    confirm_mode: config_mod.ConfirmMode = .all,
    dry_run: bool = false,
    max_turns: usize = 20,
};

/// A queued shell command waiting to be confirmed and executed.
const ShellCall = struct {
    id: []const u8,
    command: []const u8,
};

pub const Agent = struct {
    allocator: Allocator,
    cfg: *const config_mod.Config,
    messages: std.ArrayList(provider.Message) = .empty,
    /// Shell commands that were actually executed during this session.
    executed_commands: std.ArrayList([]const u8) = .empty,
    options: AgentOptions,
    stderr: std.fs.File.DeprecatedWriter,
    system_prompt: []const u8,

    pub fn init(allocator: Allocator, cfg: *const config_mod.Config, options: AgentOptions) !Agent {
        const prompt = try buildSystemPrompt(allocator);
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .options = options,
            .stderr = std.fs.File.stderr().deprecatedWriter(),
            .system_prompt = prompt,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.allocator.free(self.system_prompt);
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        for (self.executed_commands.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.executed_commands.deinit(self.allocator);
    }

    /// Run the agent with a user task.
    pub fn run(self: *Agent, task: []const u8) !void {
        // Add the user's task as the first message
        const user_msg = try provider.Message.text(self.allocator, .user, task);
        try self.messages.append(self.allocator, user_msg);

        var turn: usize = 0;
        while (turn < self.options.max_turns) : (turn += 1) {
            // Call the LLM with a spinner for visual feedback
            var spinner = Spinner.init();
            spinner.start();
            errdefer spinner.stop();
            var response = self.callLlm() catch |err| {
                spinner.stop();
                // Print diagnostic details now that the spinner is stopped.
                // Provider code cannot safely write to stderr while the spinner
                // thread is running, so diagnostic info is stashed and printed here.
                if (gemini.last_parse_error) |detail| {
                    try self.stderr.print("Gemini: {s}\n", .{detail});
                    gemini.last_parse_error = null;
                }
                if (proxy.last_error_body) |body| {
                    try self.stderr.print("Response body: {s}\n", .{body});
                    self.allocator.free(body);
                    proxy.last_error_body = null;
                }
                return err;
            };
            spinner.stop();
            // Free response on any error path; normal paths call deinit() explicitly below.
            errdefer response.deinit(self.allocator);

            // Warn when any rate limit tier is at or below 20% remaining
            if (response.rate_limit) |rl| {
                const warn_burst = rl.limit_burst > 0 and rl.remaining_burst * 5 <= rl.limit_burst;
                const warn_hourly = rl.limit_hourly > 0 and rl.remaining_hourly * 5 <= rl.limit_hourly;
                const warn_daily = rl.limit_daily > 0 and rl.remaining_daily * 5 <= rl.limit_daily;

                if (warn_burst or warn_hourly or warn_daily) {
                    try self.stderr.writeAll("\x1b[33m[warning] rate limit:");
                    var first = true;
                    if (warn_burst) {
                        try self.stderr.print(" {d}/{d} burst", .{ rl.remaining_burst, rl.limit_burst });
                        first = false;
                    }
                    if (warn_hourly) {
                        if (!first) try self.stderr.writeAll(" ·");
                        try self.stderr.print(" {d}/{d} hourly", .{ rl.remaining_hourly, rl.limit_hourly });
                        first = false;
                    }
                    if (warn_daily) {
                        if (!first) try self.stderr.writeAll(" ·");
                        try self.stderr.print(" {d}/{d} daily", .{ rl.remaining_daily, rl.limit_daily });
                    }
                    try self.stderr.writeAll(" remaining\x1b[0m\n");
                }
            }

            // Print any text content (thinking display)
            for (response.message.content) |block| {
                switch (block) {
                    .text => |text| {
                        try self.stderr.print("\x1b[90m~ {s}\x1b[0m\n", .{text});
                    },
                    else => {},
                }
            }

            // If no tool calls, we're done
            if (!response.message.hasToolCalls()) {
                response.deinit(self.allocator);
                break;
            }

            // Clone the assistant message into our history before processing tool calls
            const cloned_msg = try self.cloneMessage(&response.message);
            try self.messages.append(self.allocator, cloned_msg);

            // Separate tool calls into ask_user (immediate) and run_shell (batched)
            // First, handle any ask_user calls immediately
            for (response.message.content) |block| {
                switch (block) {
                    .tool_call => |tc| {
                        if (std.mem.eql(u8, tc.name, "ask_user")) {
                            const result = self.executeAskUserTool(tc.arguments) catch {
                                const tool_msg = try provider.Message.toolResult(
                                    self.allocator,
                                    tc.id,
                                    "Error: could not parse ask_user arguments.",
                                );
                                try self.messages.append(self.allocator, tool_msg);
                                continue;
                            };
                            defer self.allocator.free(result);

                            const tool_msg = try provider.Message.toolResult(
                                self.allocator,
                                tc.id,
                                result,
                            );
                            try self.messages.append(self.allocator, tool_msg);
                        }
                    },
                    else => {},
                }
            }

            // Collect all run_shell calls into a batch
            var shell_calls: std.ArrayList(ShellCall) = .empty;
            defer shell_calls.deinit(self.allocator);

            for (response.message.content) |block| {
                switch (block) {
                    .tool_call => |tc| {
                        if (std.mem.eql(u8, tc.name, "run_shell")) {
                            const command = extractJsonString(self.allocator, tc.arguments, "command") catch {
                                // Append error result for malformed args
                                const tool_msg = try provider.Message.toolResult(
                                    self.allocator,
                                    tc.id,
                                    "Error: could not parse command from arguments.",
                                );
                                try self.messages.append(self.allocator, tool_msg);
                                continue;
                            };
                            try shell_calls.append(self.allocator, .{
                                .id = tc.id,
                                .command = command,
                            });
                        } else if (!std.mem.eql(u8, tc.name, "ask_user")) {
                            // Unknown tool
                            const tool_msg = try provider.Message.toolResult(
                                self.allocator,
                                tc.id,
                                "Unknown tool",
                            );
                            try self.messages.append(self.allocator, tool_msg);
                        }
                    },
                    else => {},
                }
            }

            // If we have shell commands, display them all and confirm once
            if (shell_calls.items.len > 0) {
                // Display all commands, handling multi-line scripts
                try self.stderr.print("\n", .{});
                for (shell_calls.items) |sc| {
                    var lines = std.mem.splitScalar(u8, sc.command, '\n');
                    while (lines.next()) |line| {
                        const trimmed = std.mem.trim(u8, line, " \t\r");
                        if (trimmed.len == 0) continue;
                        try self.stderr.print("  $ {s}\n", .{trimmed});
                    }
                }

                if (self.options.dry_run) {
                    // Dry-run: report all as not executed
                    for (shell_calls.items) |sc| {
                        const tool_msg = try provider.Message.toolResult(
                            self.allocator,
                            sc.id,
                            "[dry-run] Command not executed.",
                        );
                        try self.messages.append(self.allocator, tool_msg);
                    }
                } else {
                    // Check if confirmation is needed
                    const needs_confirm = switch (self.options.confirm_mode) {
                        .all => true,
                        .destructive => blk: {
                            for (shell_calls.items) |sc| {
                                if (isDestructive(sc.command)) break :blk true;
                            }
                            break :blk false;
                        },
                        .none => false,
                    };

                    if (needs_confirm) {
                        const confirmed = try confirm.ask("Execute?", false);
                        if (!confirmed) {
                            // User declined — stop immediately
                            for (shell_calls.items) |sc| {
                                self.allocator.free(sc.command);
                            }
                            response.deinit(self.allocator);
                            return;
                        }
                    }

                    // Execute all commands sequentially and print output
                    try self.stderr.print("\n", .{});
                    for (shell_calls.items) |sc| {
                        // Record this command in the session history
                        const cmd_copy = try self.allocator.dupe(u8, sc.command);
                        try self.executed_commands.append(self.allocator, cmd_copy);

                        var result = try shell.execute(self.allocator, sc.command);
                        defer result.deinit();

                        // Print command output
                        if (result.stdout.len > 0) {
                            try self.stderr.print("{s}", .{result.stdout});
                            if (result.stdout[result.stdout.len - 1] != '\n') {
                                try self.stderr.print("\n", .{});
                            }
                        }
                        if (result.stderr.len > 0) {
                            try self.stderr.print("\x1b[90m{s}\x1b[0m", .{result.stderr});
                            if (result.stderr[result.stderr.len - 1] != '\n') {
                                try self.stderr.print("\n", .{});
                            }
                        }

                        const formatted = try result.format(self.allocator);
                        defer self.allocator.free(formatted);

                        const tool_msg = try provider.Message.toolResult(
                            self.allocator,
                            sc.id,
                            formatted,
                        );
                        try self.messages.append(self.allocator, tool_msg);
                    }
                }

                // Free extracted command strings
                for (shell_calls.items) |sc| {
                    self.allocator.free(sc.command);
                }
            }

            // Free the response after we're done using its content
            response.deinit(self.allocator);
        }

        // Warn if the agent hit the turn limit
        if (turn >= self.options.max_turns) {
            try self.stderr.print("\n\x1b[33m[warning]\x1b[0m Reached the maximum of {d} turns. Use --max-turns to increase.\n", .{self.options.max_turns});
        }
    }

    fn callLlm(self: *Agent) !provider.ChatResponse {
        return switch (self.cfg.provider) {
            .proxy => proxy.chat(
                self.allocator,
                self.cfg.proxy_model,
                self.system_prompt,
                self.messages.items,
                &TOOLS,
                self.cfg.proxy_url,
            ),
            .anthropic => blk: {
                const api_key = self.cfg.anthropic_api_key orelse return error.NoApiKey;
                break :blk anthropic.chat(
                    self.allocator,
                    api_key,
                    self.cfg.anthropic_model,
                    self.system_prompt,
                    self.messages.items,
                    &TOOLS,
                );
            },
            .openai => blk: {
                const api_key = self.cfg.openai_api_key orelse return error.NoApiKey;
                break :blk openai.chat(
                    self.allocator,
                    api_key,
                    self.cfg.openai_model,
                    self.system_prompt,
                    self.messages.items,
                    &TOOLS,
                    null,
                );
            },
            .gemini => blk: {
                const api_key = self.cfg.gemini_api_key orelse return error.NoApiKey;
                break :blk gemini.chat(
                    self.allocator,
                    api_key,
                    self.cfg.gemini_model,
                    self.system_prompt,
                    self.messages.items,
                    &TOOLS,
                    null, // use default Gemini URL
                );
            },
            .ollama => ollama.chat(
                self.allocator,
                self.cfg.ollama_model,
                self.system_prompt,
                self.messages.items,
                &TOOLS,
                self.cfg.ollama_host,
            ),
        };
    }

    fn executeAskUserTool(self: *Agent, arguments_json: []const u8) ![]const u8 {
        const question = extractJsonString(self.allocator, arguments_json, "question") catch {
            return self.allocator.dupe(u8, "Error: could not parse 'question' from arguments.");
        };
        defer self.allocator.free(question);

        const options_json = extractJsonString(self.allocator, arguments_json, "options") catch {
            // options missing — fall back to a simple yes/no prompt
            if (self.options.dry_run) {
                try self.stderr.print("  [dry-run] Would ask: {s}\n", .{question});
                return self.allocator.dupe(u8, "yes");
            }
            const answer = try confirm.askUser(self.allocator, question, &.{}, null);
            return answer;
        };
        defer self.allocator.free(options_json);

        // Parse the recommended index (optional)
        const recommended: ?usize = blk: {
            const rec_str = extractJsonString(self.allocator, arguments_json, "recommended") catch break :blk null;
            defer self.allocator.free(rec_str);
            break :blk std.fmt.parseInt(usize, rec_str, 10) catch null;
        };

        // Parse the options JSON array
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, options_json, .{}) catch {
            return self.allocator.dupe(u8, "Error: could not parse options array.");
        };
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return self.allocator.dupe(u8, "Error: options must be a JSON array."),
        };

        // Build a slice of option strings
        var options_list: std.ArrayList([]const u8) = .empty;
        defer options_list.deinit(self.allocator);
        for (arr.items) |item| {
            switch (item) {
                .string => |s| try options_list.append(self.allocator, s),
                else => {},
            }
        }

        if (self.options.dry_run) {
            try self.stderr.print("  [dry-run] Would ask: {s}\n", .{question});
            if (options_list.items.len > 0) {
                return self.allocator.dupe(u8, options_list.items[0]);
            }
            return self.allocator.dupe(u8, "");
        }

        return confirm.askUser(self.allocator, question, options_list.items, recommended);
    }

    fn cloneMessage(self: *Agent, msg: *const provider.Message) !provider.Message {
        const new_content = try self.allocator.alloc(provider.ContentBlock, msg.content.len);
        for (msg.content, 0..) |block, i| {
            new_content[i] = switch (block) {
                .text => |t| .{ .text = try self.allocator.dupe(u8, t) },
                .tool_call => |tc| .{
                    .tool_call = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .arguments = try self.allocator.dupe(u8, tc.arguments),
                    },
                },
            };
        }

        return .{
            .role = msg.role,
            .content = new_content,
            .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
            .raw_parts = if (msg.raw_parts) |rp| try self.allocator.dupe(u8, rp) else null,
        };
    }
};

/// Extract a string field from a JSON object.
fn extractJsonString(allocator: Allocator, json_str: []const u8, field: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const value = if (obj.get(field)) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidResponse,
    } else return error.InvalidResponse;

    return allocator.dupe(u8, value);
}

/// Check if a command looks destructive.
pub fn isDestructive(command: []const u8) bool {
    const patterns = [_][]const u8{
        "kill ",
        "killall ",
        "pkill ",
        "rm ",
        "rm -",
        "rmdir ",
        "drop ",
        "truncate ",
        "shutdown",
        "reboot",
        "mkfs",
        "dd ",
        "format ",
        "> /dev/",
    };

    const lower = blk: {
        var buf_arr: [4096]u8 = undefined;
        const len = @min(command.len, buf_arr.len);
        for (0..len) |i| {
            buf_arr[i] = std.ascii.toLower(command[i]);
        }
        break :blk buf_arr[0..len];
    };

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) return true;
    }
    return false;
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "isDestructive detects kill commands" {
    try std.testing.expect(isDestructive("kill 1234"));
    try std.testing.expect(isDestructive("killall node"));
    try std.testing.expect(isDestructive("pkill -9 python"));
}

test "isDestructive detects rm commands" {
    try std.testing.expect(isDestructive("rm file.txt"));
    try std.testing.expect(isDestructive("rm -rf /tmp/stuff"));
    try std.testing.expect(isDestructive("rmdir empty_dir"));
}

test "isDestructive detects other dangerous patterns" {
    try std.testing.expect(isDestructive("drop table users"));
    try std.testing.expect(isDestructive("truncate big_table"));
    try std.testing.expect(isDestructive("shutdown -h now"));
    try std.testing.expect(isDestructive("reboot"));
    try std.testing.expect(isDestructive("mkfs.ext4 /dev/sda1"));
    try std.testing.expect(isDestructive("dd if=/dev/zero of=/dev/sda"));
    try std.testing.expect(isDestructive("format C:"));
    try std.testing.expect(isDestructive("echo oops > /dev/sda"));
}

test "isDestructive is case-insensitive" {
    try std.testing.expect(isDestructive("KILL 1234"));
    try std.testing.expect(isDestructive("Rm -Rf /tmp"));
    try std.testing.expect(isDestructive("SHUTDOWN"));
    try std.testing.expect(isDestructive("Reboot"));
    try std.testing.expect(isDestructive("DD if=x of=y"));
}

test "isDestructive returns false for safe commands" {
    try std.testing.expect(!isDestructive("ls -la"));
    try std.testing.expect(!isDestructive("cat file.txt"));
    try std.testing.expect(!isDestructive("grep -r pattern ."));
    try std.testing.expect(!isDestructive("echo hello"));
    try std.testing.expect(!isDestructive("pwd"));
    try std.testing.expect(!isDestructive("ps aux"));
    try std.testing.expect(!isDestructive("curl https://example.com"));
    try std.testing.expect(!isDestructive("mkdir new_dir"));
}

test "isDestructive handles empty command" {
    try std.testing.expect(!isDestructive(""));
}

test "isDestructive detects pattern in middle of command" {
    try std.testing.expect(isDestructive("sudo kill -9 1234"));
    try std.testing.expect(isDestructive("sudo rm -rf /"));
    try std.testing.expect(isDestructive("echo data > /dev/sda"));
}

test "extractJsonString extracts valid field" {
    const allocator = std.testing.allocator;
    const result = try extractJsonString(allocator, "{\"command\":\"ls -la\"}", "command");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
}

test "extractJsonString returns error for missing field" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "{\"other\":\"value\"}", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString returns error for non-string field" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "{\"command\":42}", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString returns error for malformed JSON" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "not json", "command");
    try std.testing.expectError(error.JsonParseError, result);
}

test "extractJsonString returns error for JSON array" {
    const allocator = std.testing.allocator;
    const result = extractJsonString(allocator, "[1, 2, 3]", "command");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "extractJsonString handles unicode and escaped strings" {
    const allocator = std.testing.allocator;
    const result = try extractJsonString(allocator, "{\"msg\":\"hello\\nworld\"}", "msg");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld", result);
}
