const std = @import("std");
const Allocator = std.mem.Allocator;

/// Roles for messages in the conversation.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

/// A tool call requested by the LLM.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // raw JSON string

    pub fn deinit(self: *ToolCall, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

/// A content block -- either text or a tool call.
pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_call: ToolCall,

    pub fn deinit(self: *ContentBlock, allocator: Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .tool_call => |*tc| tc.deinit(allocator),
        }
    }
};

/// A message in the conversation.
pub const Message = struct {
    role: Role,
    content: []ContentBlock,
    /// For tool result messages, the tool_call_id this is responding to.
    tool_call_id: ?[]const u8 = null,
    /// Raw JSON "parts" array from Gemini responses. Used to preserve
    /// thought_signatures when replaying assistant messages back to the API.
    /// Only set for Gemini model messages that contain function calls.
    raw_parts: ?[]const u8 = null,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        for (self.content) |*block| {
            block.deinit(allocator);
        }
        allocator.free(self.content);
        if (self.tool_call_id) |id| {
            allocator.free(id);
        }
        if (self.raw_parts) |rp| {
            allocator.free(rp);
        }
    }

    /// Create a simple text message.
    pub fn text(allocator: Allocator, role: Role, txt: []const u8) !Message {
        const content = try allocator.alloc(ContentBlock, 1);
        content[0] = .{ .text = try allocator.dupe(u8, txt) };
        return .{ .role = role, .content = content };
    }

    /// Create a tool result message.
    pub fn toolResult(allocator: Allocator, tool_call_id: []const u8, result_text: []const u8) !Message {
        const content = try allocator.alloc(ContentBlock, 1);
        content[0] = .{ .text = try allocator.dupe(u8, result_text) };
        return .{
            .role = .tool,
            .content = content,
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
        };
    }

    /// Get the text content if this is a simple text message.
    pub fn getText(self: *const Message) ?[]const u8 {
        if (self.content.len == 0) return null;
        switch (self.content[0]) {
            .text => |t| return t,
            else => return null,
        }
    }

    /// Check if the message contains any tool calls.
    pub fn hasToolCalls(self: *const Message) bool {
        for (self.content) |block| {
            switch (block) {
                .tool_call => return true,
                else => {},
            }
        }
        return false;
    }
};

/// Tool parameter property definition.
pub const ToolProperty = struct {
    name: []const u8,
    type: []const u8 = "string",
    description: []const u8,
};

/// Tool definition to send to the LLM.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    properties: []const ToolProperty,
    required: []const []const u8,
};

/// Stop reason from the LLM.
pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    unknown,

    pub fn fromString(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn") or std.mem.eql(u8, s, "stop")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_use") or std.mem.eql(u8, s, "tool_calls")) return .tool_use;
        if (std.mem.eql(u8, s, "max_tokens") or std.mem.eql(u8, s, "length")) return .max_tokens;
        return .unknown;
    }
};

/// Rate limit information returned by the pls proxy.
/// Only set when using the proxy provider; null for all other providers.
pub const RateLimitInfo = struct {
    remaining_burst: u32,
    limit_burst: u32,
    remaining_hourly: u32,
    limit_hourly: u32,
    remaining_daily: u32,
    limit_daily: u32,
};

/// Response from an LLM chat call.
pub const ChatResponse = struct {
    message: Message,
    stop_reason: StopReason,
    /// Rate limit usage from the proxy. Null for non-proxy providers.
    rate_limit: ?RateLimitInfo = null,

    pub fn deinit(self: *ChatResponse, allocator: Allocator) void {
        self.message.deinit(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "Role.toString returns correct strings" {
    try std.testing.expectEqualStrings("system", Role.system.toString());
    try std.testing.expectEqualStrings("user", Role.user.toString());
    try std.testing.expectEqualStrings("assistant", Role.assistant.toString());
    try std.testing.expectEqualStrings("tool", Role.tool.toString());
}

test "StopReason.fromString maps Anthropic values" {
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("end_turn"));
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_use"));
    try std.testing.expectEqual(StopReason.max_tokens, StopReason.fromString("max_tokens"));
}

test "StopReason.fromString maps OpenAI values" {
    try std.testing.expectEqual(StopReason.end_turn, StopReason.fromString("stop"));
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_calls"));
    try std.testing.expectEqual(StopReason.max_tokens, StopReason.fromString("length"));
}

test "StopReason.fromString returns unknown for unrecognized" {
    try std.testing.expectEqual(StopReason.unknown, StopReason.fromString(""));
    try std.testing.expectEqual(StopReason.unknown, StopReason.fromString("something_else"));
    try std.testing.expectEqual(StopReason.unknown, StopReason.fromString("STOP"));
}

test "Message.text creates a text message" {
    const allocator = std.testing.allocator;
    var msg = try Message.text(allocator, .user, "hello world");
    defer msg.deinit(allocator);

    try std.testing.expectEqual(Role.user, msg.role);
    try std.testing.expect(msg.content.len == 1);
    try std.testing.expectEqualStrings("hello world", msg.getText().?);
    try std.testing.expect(msg.tool_call_id == null);
    try std.testing.expect(msg.raw_parts == null);
    try std.testing.expect(!msg.hasToolCalls());
}

test "Message.toolResult creates a tool result message" {
    const allocator = std.testing.allocator;
    var msg = try Message.toolResult(allocator, "call-123", "Exit code: 0\n");
    defer msg.deinit(allocator);

    try std.testing.expectEqual(Role.tool, msg.role);
    try std.testing.expectEqualStrings("call-123", msg.tool_call_id.?);
    try std.testing.expectEqualStrings("Exit code: 0\n", msg.getText().?);
    try std.testing.expect(!msg.hasToolCalls());
}

test "Message.hasToolCalls returns true when tool call present" {
    const allocator = std.testing.allocator;
    var content = try allocator.alloc(ContentBlock, 2);
    content[0] = .{ .text = try allocator.dupe(u8, "I'll run a command") };
    content[1] = .{
        .tool_call = .{
            .id = try allocator.dupe(u8, "tc-1"),
            .name = try allocator.dupe(u8, "run_shell"),
            .arguments = try allocator.dupe(u8, "{\"command\":\"ls\"}"),
        },
    };

    var msg = Message{ .role = .assistant, .content = content };
    defer msg.deinit(allocator);

    try std.testing.expect(msg.hasToolCalls());
    try std.testing.expectEqualStrings("I'll run a command", msg.getText().?);
}

test "Message.getText returns null for empty content" {
    const allocator = std.testing.allocator;
    const content = try allocator.alloc(ContentBlock, 0);
    var msg = Message{ .role = .assistant, .content = content };
    defer msg.deinit(allocator);

    try std.testing.expect(msg.getText() == null);
}

test "Message.getText returns null when first block is tool_call" {
    const allocator = std.testing.allocator;
    var content = try allocator.alloc(ContentBlock, 1);
    content[0] = .{
        .tool_call = .{
            .id = try allocator.dupe(u8, "tc-1"),
            .name = try allocator.dupe(u8, "run_shell"),
            .arguments = try allocator.dupe(u8, "{}"),
        },
    };

    var msg = Message{ .role = .assistant, .content = content };
    defer msg.deinit(allocator);

    try std.testing.expect(msg.getText() == null);
    try std.testing.expect(msg.hasToolCalls());
}
