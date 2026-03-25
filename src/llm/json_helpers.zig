const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");

/// Escape a string for JSON output.
pub fn escapeJsonString(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try result.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Build the tools JSON array for the OpenAI/Ollama function calling format.
pub fn buildOpenAIToolsJson(allocator: Allocator, tools: []const provider.Tool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
        try w.writeAll(tool.name);
        try w.writeAll("\",\"description\":\"");
        const desc = try escapeJsonString(allocator, tool.description);
        defer allocator.free(desc);
        try w.writeAll(desc);
        try w.writeAll("\",\"parameters\":{\"type\":\"object\",\"properties\":{");

        for (tool.properties, 0..) |prop, j| {
            if (j > 0) try w.writeAll(",");
            const prop_name = try escapeJsonString(allocator, prop.name);
            defer allocator.free(prop_name);
            const prop_desc = try escapeJsonString(allocator, prop.description);
            defer allocator.free(prop_desc);
            try w.print("\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{
                prop_name,
                prop.type,
                prop_desc,
            });
        }

        try w.writeAll("},\"required\":[");
        for (tool.required, 0..) |req, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{req});
        }
        try w.writeAll("]}}}");
    }
    try w.writeAll("]");

    return buf.toOwnedSlice(allocator);
}

/// Build the tools JSON array for the Anthropic format.
pub fn buildAnthropicToolsJson(allocator: Allocator, tools: []const provider.Tool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(tool.name);
        try w.writeAll("\",\"description\":\"");
        const desc = try escapeJsonString(allocator, tool.description);
        defer allocator.free(desc);
        try w.writeAll(desc);
        try w.writeAll("\",\"input_schema\":{\"type\":\"object\",\"properties\":{");

        for (tool.properties, 0..) |prop, j| {
            if (j > 0) try w.writeAll(",");
            const prop_name = try escapeJsonString(allocator, prop.name);
            defer allocator.free(prop_name);
            const prop_desc = try escapeJsonString(allocator, prop.description);
            defer allocator.free(prop_desc);
            try w.print("\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{
                prop_name,
                prop.type,
                prop_desc,
            });
        }

        try w.writeAll("},\"required\":[");
        for (tool.required, 0..) |req, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{req});
        }
        try w.writeAll("]}}");
    }
    try w.writeAll("]");

    return buf.toOwnedSlice(allocator);
}

/// Build messages JSON for OpenAI/Ollama format.
pub fn buildOpenAIMessagesJson(allocator: Allocator, system_prompt: []const u8, messages: []const provider.Message) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");

    // System message
    try w.writeAll("{\"role\":\"system\",\"content\":\"");
    const sys_escaped = try escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    try w.writeAll(sys_escaped);
    try w.writeAll("\"}");

    for (messages) |msg| {
        try w.writeAll(",");
        if (msg.role == .tool) {
            try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":\"");
            if (msg.tool_call_id) |id| try w.writeAll(id);
            try w.writeAll("\",\"content\":\"");
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}");
        } else if (msg.role == .assistant and msg.hasToolCalls()) {
            try w.writeAll("{\"role\":\"assistant\",\"content\":");

            if (msg.getText()) |txt| {
                try w.writeAll("\"");
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
                try w.writeAll("\"");
            } else {
                try w.writeAll("null");
            }

            try w.writeAll(",\"tool_calls\":[");
            var tc_idx: usize = 0;
            for (msg.content) |block| {
                switch (block) {
                    .tool_call => |tc| {
                        if (tc_idx > 0) try w.writeAll(",");
                        const escaped_args = try escapeJsonString(allocator, tc.arguments);
                        defer allocator.free(escaped_args);
                        try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}", .{
                            tc.id,
                            tc.name,
                            escaped_args,
                        });
                        tc_idx += 1;
                    },
                    else => {},
                }
            }
            try w.writeAll("]}");
        } else {
            try w.print("{{\"role\":\"{s}\",\"content\":\"", .{msg.role.toString()});
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}");
        }
    }

    try w.writeAll("]");
    return buf.toOwnedSlice(allocator);
}

/// Build the tools JSON for the Gemini function calling format.
/// Gemini uses: [{"functionDeclarations": [...]}]
pub fn buildGeminiToolsJson(allocator: Allocator, tools: []const provider.Tool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[{\"functionDeclarations\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(tool.name);
        try w.writeAll("\",\"description\":\"");
        const desc = try escapeJsonString(allocator, tool.description);
        defer allocator.free(desc);
        try w.writeAll(desc);
        try w.writeAll("\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{");

        for (tool.properties, 0..) |prop, j| {
            if (j > 0) try w.writeAll(",");
            const prop_name = try escapeJsonString(allocator, prop.name);
            defer allocator.free(prop_name);
            const prop_desc = try escapeJsonString(allocator, prop.description);
            defer allocator.free(prop_desc);
            try w.print("\"{s}\":{{\"type\":\"STRING\",\"description\":\"{s}\"}}", .{
                prop_name,
                prop_desc,
            });
        }

        try w.writeAll("},\"required\":[");
        for (tool.required, 0..) |req, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{req});
        }
        try w.writeAll("]}}");
    }
    try w.writeAll("]}]");

    return buf.toOwnedSlice(allocator);
}

/// Build contents JSON for Gemini format.
/// Gemini uses: role "user" / "model", parts with text or functionCall/functionResponse.
pub fn buildGeminiContentsJson(allocator: Allocator, messages: []const provider.Message) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");

    var first = true;
    for (messages) |msg| {
        if (!first) try w.writeAll(",");
        first = false;

        if (msg.role == .tool) {
            // Tool result -> user role with functionResponse part
            try w.writeAll("{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"");
            // tool_call_id stores the function name for Gemini
            if (msg.tool_call_id) |id| {
                try w.writeAll(id);
            }
            try w.writeAll("\",\"response\":{\"result\":\"");
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}}}]}");
        } else if (msg.role == .assistant) {
            // If we have raw_parts (captured verbatim from Gemini response),
            // use it directly to preserve thought_signatures.
            if (msg.raw_parts) |rp| {
                try w.writeAll("{\"role\":\"model\",\"parts\":");
                try w.writeAll(rp);
                try w.writeAll("}");
            } else {
                try w.writeAll("{\"role\":\"model\",\"parts\":[");
                var part_idx: usize = 0;
                for (msg.content) |block| {
                    if (part_idx > 0) try w.writeAll(",");
                    switch (block) {
                        .text => |txt| {
                            try w.writeAll("{\"text\":\"");
                            const escaped = try escapeJsonString(allocator, txt);
                            defer allocator.free(escaped);
                            try w.writeAll(escaped);
                            try w.writeAll("\"}");
                        },
                        .tool_call => |tc| {
                            try w.print("{{\"functionCall\":{{\"name\":\"{s}\",\"args\":{s}}}}}", .{
                                tc.name,
                                tc.arguments,
                            });
                        },
                    }
                    part_idx += 1;
                }
                try w.writeAll("]}");
            }
        } else {
            // User message
            try w.writeAll("{\"role\":\"user\",\"parts\":[{\"text\":\"");
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}]}");
        }
    }

    try w.writeAll("]");
    return buf.toOwnedSlice(allocator);
}
/// Build messages JSON for Anthropic format.
pub fn buildAnthropicMessagesJson(allocator: Allocator, messages: []const provider.Message) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");

    for (messages, 0..) |msg, msg_idx| {
        if (msg_idx > 0) try w.writeAll(",");

        if (msg.role == .tool) {
            try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"");
            if (msg.tool_call_id) |id| try w.writeAll(id);
            try w.writeAll("\",\"content\":\"");
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}]}");
        } else if (msg.role == .assistant and msg.hasToolCalls()) {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            var block_idx: usize = 0;
            for (msg.content) |block| {
                if (block_idx > 0) try w.writeAll(",");
                switch (block) {
                    .text => |txt| {
                        try w.writeAll("{\"type\":\"text\",\"text\":\"");
                        const escaped = try escapeJsonString(allocator, txt);
                        defer allocator.free(escaped);
                        try w.writeAll(escaped);
                        try w.writeAll("\"}");
                    },
                    .tool_call => |tc| {
                        try w.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{
                            tc.id,
                            tc.name,
                            tc.arguments,
                        });
                    },
                }
                block_idx += 1;
            }
            try w.writeAll("]}");
        } else {
            try w.print("{{\"role\":\"{s}\",\"content\":\"", .{msg.role.toString()});
            if (msg.getText()) |txt| {
                const escaped = try escapeJsonString(allocator, txt);
                defer allocator.free(escaped);
                try w.writeAll(escaped);
            }
            try w.writeAll("\"}");
        }
    }

    try w.writeAll("]");
    return buf.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

fn testTextMsg(allocator: Allocator, role: provider.Role, txt: []const u8) !provider.Message {
    return provider.Message.text(allocator, role, txt);
}

fn testToolCallMsg(allocator: Allocator) !provider.Message {
    const content = try allocator.alloc(provider.ContentBlock, 2);
    content[0] = .{ .text = try allocator.dupe(u8, "Let me run that.") };
    content[1] = .{
        .tool_call = .{
            .id = try allocator.dupe(u8, "call-1"),
            .name = try allocator.dupe(u8, "run_shell"),
            .arguments = try allocator.dupe(u8, "{\"command\":\"ls\"}"),
        },
    };
    return .{ .role = .assistant, .content = content };
}

fn testToolResultMsg(allocator: Allocator) !provider.Message {
    return provider.Message.toolResult(allocator, "call-1", "Exit code: 0\n");
}

test "escapeJsonString plain ASCII" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "hello world");
    defer a.free(r);
    try std.testing.expectEqualStrings("hello world", r);
}

test "escapeJsonString empty string" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "escapeJsonString double quotes" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "say \"hello\"");
    defer a.free(r);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", r);
}

test "escapeJsonString backslash" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "path\\to\\file");
    defer a.free(r);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", r);
}

test "escapeJsonString newline tab cr" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "line1\nline2\ttab\rreturn");
    defer a.free(r);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\rreturn", r);
}

test "escapeJsonString control character" {
    const a = std.testing.allocator;
    const r = try escapeJsonString(a, "a\x01b");
    defer a.free(r);
    try std.testing.expectEqualStrings("a\\u0001b", r);
}

test "buildOpenAIToolsJson single tool" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{.{
        .name = "run_shell",
        .description = "Execute a command.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "command", .type = "string", .description = "The command" },
        },
        .required = &[_][]const u8{"command"},
    }};
    const r = try buildOpenAIToolsJson(a, &tools);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"type":"function","function":{"name":"run_shell","description":"Execute a command.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The command"}},"required":["command"]}}}]
    , r);
}

test "buildOpenAIToolsJson empty" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{};
    const r = try buildOpenAIToolsJson(a, &tools);
    defer a.free(r);
    try std.testing.expectEqualStrings("[]", r);
}

test "buildAnthropicToolsJson single tool" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{.{
        .name = "run_shell",
        .description = "Execute a command.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "command", .type = "string", .description = "The command" },
        },
        .required = &[_][]const u8{"command"},
    }};
    const r = try buildAnthropicToolsJson(a, &tools);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"name":"run_shell","description":"Execute a command.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The command"}},"required":["command"]}}]
    , r);
}

test "buildGeminiToolsJson single tool" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{.{
        .name = "run_shell",
        .description = "Execute a command.",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "command", .type = "string", .description = "The command" },
        },
        .required = &[_][]const u8{"command"},
    }};
    const r = try buildGeminiToolsJson(a, &tools);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"functionDeclarations":[{"name":"run_shell","description":"Execute a command.","parameters":{"type":"OBJECT","properties":{"command":{"type":"STRING","description":"The command"}},"required":["command"]}}]}]
    , r);
}

test "buildOpenAIMessagesJson system and user" {
    const a = std.testing.allocator;
    var m = try testTextMsg(a, .user, "hello");
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildOpenAIMessagesJson(a, "You are helpful.", &msgs);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"role":"system","content":"You are helpful."},{"role":"user","content":"hello"}]
    , r);
}

test "buildOpenAIMessagesJson assistant with tool call" {
    const a = std.testing.allocator;
    var m = try testToolCallMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildOpenAIMessagesJson(a, "sys", &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"tool_calls\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"name\":\"run_shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"id\":\"call-1\"") != null);
    // arguments must be a JSON-encoded string, not a raw object (required by Ollama)
    try std.testing.expect(std.mem.indexOf(u8, r, "\"arguments\":\"{") != null);
}

test "buildOpenAIMessagesJson tool result" {
    const a = std.testing.allocator;
    var m = try testToolResultMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildOpenAIMessagesJson(a, "sys", &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"tool_call_id\":\"call-1\"") != null);
}

test "buildAnthropicMessagesJson user message" {
    const a = std.testing.allocator;
    var m = try testTextMsg(a, .user, "do it");
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildAnthropicMessagesJson(a, &msgs);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":"do it"}]
    , r);
}

test "buildAnthropicMessagesJson assistant with tool call" {
    const a = std.testing.allocator;
    var m = try testToolCallMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildAnthropicMessagesJson(a, &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"id\":\"call-1\"") != null);
}

test "buildAnthropicMessagesJson tool result" {
    const a = std.testing.allocator;
    var m = try testToolResultMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildAnthropicMessagesJson(a, &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"tool_use_id\":\"call-1\"") != null);
}

test "buildGeminiContentsJson user message" {
    const a = std.testing.allocator;
    var m = try testTextMsg(a, .user, "hello");
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildGeminiContentsJson(a, &msgs);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","parts":[{"text":"hello"}]}]
    , r);
}

test "buildGeminiContentsJson model text" {
    const a = std.testing.allocator;
    var m = try testTextMsg(a, .assistant, "Sure!");
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildGeminiContentsJson(a, &msgs);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"role":"model","parts":[{"text":"Sure!"}]}]
    , r);
}

test "buildGeminiContentsJson raw_parts passthrough" {
    const a = std.testing.allocator;
    const content = try a.alloc(provider.ContentBlock, 1);
    content[0] = .{ .text = try a.dupe(u8, "ignored") };
    const raw = try a.dupe(u8, "[{\"text\":\"raw\"}]");
    var m = provider.Message{ .role = .assistant, .content = content, .raw_parts = raw };
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildGeminiContentsJson(a, &msgs);
    defer a.free(r);
    try std.testing.expectEqualStrings(
        \\[{"role":"model","parts":[{"text":"raw"}]}]
    , r);
}

test "buildGeminiContentsJson tool result" {
    const a = std.testing.allocator;
    var m = try testToolResultMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildGeminiContentsJson(a, &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"functionResponse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"name\":\"call-1\"") != null);
}

test "buildGeminiContentsJson tool call no raw_parts" {
    const a = std.testing.allocator;
    var m = try testToolCallMsg(a);
    defer m.deinit(a);
    const msgs = [_]provider.Message{m};
    const r = try buildGeminiContentsJson(a, &msgs);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"functionCall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"name\":\"run_shell\"") != null);
}

test "buildOpenAIToolsJson multiple tools" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{
        .{ .name = "a", .description = "A", .properties = &[_]provider.ToolProperty{}, .required = &[_][]const u8{} },
        .{ .name = "b", .description = "B", .properties = &[_]provider.ToolProperty{}, .required = &[_][]const u8{} },
    };
    const r = try buildOpenAIToolsJson(a, &tools);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"name\":\"b\"") != null);
}

test "tool description with special characters gets escaped" {
    const a = std.testing.allocator;
    const tools = [_]provider.Tool{.{
        .name = "t",
        .description = "Has \"quotes\"\nand newlines",
        .properties = &[_]provider.ToolProperty{
            .{ .name = "x", .type = "string", .description = "Also \"quoted\"" },
        },
        .required = &[_][]const u8{"x"},
    }};

    const r1 = try buildOpenAIToolsJson(a, &tools);
    defer a.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "Also \\\"quoted\\\"") != null);

    const r2 = try buildAnthropicToolsJson(a, &tools);
    defer a.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "\\\"quotes\\\"") != null);

    const r3 = try buildGeminiToolsJson(a, &tools);
    defer a.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "\\\"quotes\\\"") != null);
}
