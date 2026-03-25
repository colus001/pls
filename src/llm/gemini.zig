const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const json_helpers = @import("json_helpers.zig");
const http_client = @import("http_client.zig");

const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com";

/// Diagnostic message set by parseResponse when returning error.InvalidResponse.
/// Read by agent.zig after stopping the spinner. Static string literal — no allocation.
pub var last_parse_error: ?[]const u8 = null;

/// Send a chat request to the Google Gemini API.
/// When `base_url` is provided, it is used instead of the default Gemini URL
/// (e.g. for proxy endpoints). When `api_key` is null, the `?key=` query
/// parameter is omitted (the proxy injects it server-side).
pub fn chat(
    allocator: Allocator,
    api_key: ?[]const u8,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
    base_url: ?[]const u8,
) !provider.ChatResponse {
    const body = try buildRequestBody(allocator, system_prompt, messages, tools);
    defer allocator.free(body);

    const base = base_url orelse GEMINI_BASE_URL;

    // Build URL: append ?key= only when an API key is provided
    const url = if (api_key) |key|
        try std.fmt.allocPrint(
            allocator,
            "{s}/v1beta/models/{s}:generateContent?key={s}",
            .{ base, model, key },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}/v1beta/models/{s}:generateContent",
            .{ base, model },
        );
    defer allocator.free(url);

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const response_body = try http_client.post(allocator, url, &headers, body);
    defer allocator.free(response_body);

    return parseResponse(allocator, response_body);
}

fn buildRequestBody(
    allocator: Allocator,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // System instruction
    try w.writeAll("{\"system_instruction\":{\"parts\":[{\"text\":\"");
    const sys_escaped = try json_helpers.escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    try w.writeAll(sys_escaped);
    try w.writeAll("\"}]},\"contents\":");

    // Contents (messages)
    const contents_json = try json_helpers.buildGeminiContentsJson(allocator, messages);
    defer allocator.free(contents_json);
    try w.writeAll(contents_json);

    // Tools
    if (tools.len > 0) {
        try w.writeAll(",\"tools\":");
        const tools_json = try json_helpers.buildGeminiToolsJson(allocator, tools);
        defer allocator.free(tools_json);
        try w.writeAll(tools_json);
    }

    try w.writeAll("}");

    return buf.toOwnedSlice(allocator);
}

pub fn parseResponse(allocator: Allocator, body: []const u8) !provider.ChatResponse {
    last_parse_error = null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        last_parse_error = "response is not valid JSON";
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Check for error
    if (root.get("error")) |_| {
        return error.ApiError;
    }

    // Get candidates array
    const candidates = if (root.get("candidates")) |c| switch (c) {
        .array => |a| a,
        else => {
            last_parse_error = "'candidates' is not an array";
            return error.InvalidResponse;
        },
    } else {
        // Include finishReason hint when candidates is missing entirely
        const reason = if (root.get("promptFeedback")) |pf| switch (pf) {
            .object => |o| if (o.get("blockReason")) |br| switch (br) {
                .string => |s| s,
                else => null,
            } else null,
            else => null,
        } else null;
        last_parse_error = if (reason) |r|
            if (std.mem.eql(u8, r, "SAFETY"))
                "no candidates returned (blocked by safety filter)"
            else
                "no candidates returned (prompt blocked)"
        else
            "missing 'candidates' field";
        return error.InvalidResponse;
    };

    if (candidates.items.len == 0) {
        last_parse_error = "empty 'candidates' array";
        return error.InvalidResponse;
    }

    const candidate = switch (candidates.items[0]) {
        .object => |o| o,
        else => {
            last_parse_error = "candidate is not an object";
            return error.InvalidResponse;
        },
    };

    // Parse finish reason
    const finish_str = if (candidate.get("finishReason")) |fr| switch (fr) {
        .string => |s| s,
        else => "STOP",
    } else "STOP";

    const stop_reason = if (std.mem.eql(u8, finish_str, "STOP"))
        provider.StopReason.end_turn
    else if (std.mem.eql(u8, finish_str, "MAX_TOKENS"))
        provider.StopReason.max_tokens
    else
        provider.StopReason.end_turn;

    // Parse content -> parts
    const content_obj = if (candidate.get("content")) |c| switch (c) {
        .object => |o| o,
        else => {
            last_parse_error = "'content' is not an object";
            return error.InvalidResponse;
        },
    } else {
        // finishReason often explains why content is missing
        if (std.mem.eql(u8, finish_str, "SAFETY")) {
            last_parse_error = "no content returned (blocked by safety filter)";
        } else if (std.mem.eql(u8, finish_str, "RECITATION")) {
            last_parse_error = "no content returned (blocked for recitation)";
        } else {
            last_parse_error = "missing 'content' in candidate (finishReason: see API response)";
        }
        return error.InvalidResponse;
    };

    const parts_val = content_obj.get("parts") orelse {
        last_parse_error = "missing 'parts' in content";
        return error.InvalidResponse;
    };
    const parts = switch (parts_val) {
        .array => |a| a,
        else => {
            last_parse_error = "'parts' is not an array";
            return error.InvalidResponse;
        },
    };

    var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
    errdefer {
        for (content_blocks.items) |*block| block.deinit(allocator);
        content_blocks.deinit(allocator);
    }

    var has_function_call = false;

    for (parts.items) |part_val| {
        const part_obj = switch (part_val) {
            .object => |o| o,
            else => continue,
        };

        // Text part (skip thinking text — parts with "thought": true)
        if (part_obj.get("text")) |text_val| {
            const is_thought = if (part_obj.get("thought")) |th| switch (th) {
                .bool => |b| b,
                else => false,
            } else false;

            if (!is_thought) {
                switch (text_val) {
                    .string => |s| {
                        if (s.len > 0) {
                            try content_blocks.append(allocator, .{
                                .text = try allocator.dupe(u8, s),
                            });
                        }
                    },
                    else => {},
                }
            }
        }

        // Function call part
        if (part_obj.get("functionCall")) |fc_val| {
            const fc_obj = switch (fc_val) {
                .object => |o| o,
                else => continue,
            };

            const name = if (fc_obj.get("name")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            // Serialize args back to JSON
            const args_val = fc_obj.get("args") orelse continue;
            const args_json = std.json.Stringify.valueAlloc(allocator, args_val, .{}) catch continue;

            // Gemini doesn't use IDs for tool calls; use the function name as ID
            try content_blocks.append(allocator, .{
                .tool_call = .{
                    .id = try allocator.dupe(u8, name),
                    .name = try allocator.dupe(u8, name),
                    .arguments = args_json,
                },
            });
            has_function_call = true;
        }
    }

    const content = try content_blocks.toOwnedSlice(allocator);

    // Capture the raw parts JSON verbatim so we can replay it with
    // thought_signatures intact when sending history back to Gemini.
    const raw_parts: ?[]const u8 = if (has_function_call)
        std.json.Stringify.valueAlloc(allocator, parts_val, .{}) catch null
    else
        null;

    return .{
        .message = .{
            .role = .assistant,
            .content = content,
            .raw_parts = raw_parts,
        },
        .stop_reason = if (has_function_call) .tool_use else stop_reason,
    };
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "parseResponse text content" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"Hello!"}],"role":"model"},"finishReason":"STOP"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.Role.assistant, resp.message.role);
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expect(resp.message.content.len == 1);
    try std.testing.expectEqualStrings("Hello!", resp.message.getText().?);
    try std.testing.expect(!resp.message.hasToolCalls());
    try std.testing.expect(resp.message.raw_parts == null);
}

test "parseResponse functionCall" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"run_shell","args":{"command":"ls -la"}}}],"role":"model"},"finishReason":"FUNCTION_CALL"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    try std.testing.expect(resp.message.hasToolCalls());
    try std.testing.expect(resp.message.content.len == 1);

    const tc = resp.message.content[0].tool_call;
    try std.testing.expectEqualStrings("run_shell", tc.name);
    try std.testing.expectEqualStrings("run_shell", tc.id); // Gemini uses function name as ID
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments, "ls -la") != null);

    // raw_parts should be captured for function calls
    try std.testing.expect(resp.message.raw_parts != null);
}

test "parseResponse filters thought parts" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"Hello!"}],"role":"model"},"finishReason":"STOP"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    // Should only have the non-thought text
    try std.testing.expect(resp.message.content.len == 1);
    try std.testing.expectEqualStrings("Hello!", resp.message.getText().?);
}

test "parseResponse error response" {
    const a = std.testing.allocator;
    const body =
        \\{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.ApiError, result);
}

test "parseResponse malformed JSON" {
    const a = std.testing.allocator;
    const result = parseResponse(a, "not json");
    try std.testing.expectError(error.JsonParseError, result);
    try std.testing.expectEqualStrings("response is not valid JSON", last_parse_error.?);
}

test "parseResponse empty candidates" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[]}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.InvalidResponse, result);
    try std.testing.expectEqualStrings("empty 'candidates' array", last_parse_error.?);
}

test "parseResponse missing content sets diagnostic" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"finishReason":"SAFETY"}]}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.InvalidResponse, result);
    try std.testing.expectEqualStrings("no content returned (blocked by safety filter)", last_parse_error.?);
}

test "parseResponse missing candidates sets diagnostic" {
    const a = std.testing.allocator;
    const body =
        \\{"promptFeedback":{"blockReason":"SAFETY"}}
    ;
    const result = parseResponse(a, body);
    try std.testing.expectError(error.InvalidResponse, result);
    try std.testing.expectEqualStrings("no candidates returned (blocked by safety filter)", last_parse_error.?);
}

test "parseResponse MAX_TOKENS finish reason" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"truncated output"}],"role":"model"},"finishReason":"MAX_TOKENS"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expectEqual(provider.StopReason.max_tokens, resp.stop_reason);
    try std.testing.expectEqualStrings("truncated output", resp.message.getText().?);
}

test "parseResponse text with functionCall mixed" {
    const a = std.testing.allocator;
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"I'll check."},{"functionCall":{"name":"run_shell","args":{"command":"pwd"}}}],"role":"model"},"finishReason":"FUNCTION_CALL"}]}
    ;
    var resp = try parseResponse(a, body);
    defer resp.deinit(a);

    try std.testing.expect(resp.message.content.len == 2);
    try std.testing.expectEqualStrings("I'll check.", resp.message.getText().?);
    try std.testing.expect(resp.message.hasToolCalls());
    try std.testing.expectEqual(provider.StopReason.tool_use, resp.stop_reason);
    try std.testing.expect(resp.message.raw_parts != null);
}
