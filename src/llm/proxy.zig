const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const gemini = @import("gemini.zig");
const json_helpers = @import("json_helpers.zig");

/// Raw HTTP response body from the last failed API call.
/// Stored as an owned allocation so the agent can print it after stopping
/// the spinner (avoids race condition with spinner thread on stderr).
/// Caller must free with the same allocator passed to chat().
pub var last_error_body: ?[]const u8 = null;

/// Send a chat request to the pls proxy.
/// The proxy injects the Gemini API key server-side; no API key is required.
/// On success, ChatResponse.rate_limit is populated from X-RateLimit-* headers
/// if they are present. On HTTP 429, a human-readable message is printed to
/// stderr and error.RateLimited is returned.
pub fn chat(
    allocator: Allocator,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
    proxy_url: []const u8,
) !provider.ChatResponse {
    // Clear stale diagnostic from a previous call
    if (last_error_body) |prev| {
        allocator.free(prev);
        last_error_body = null;
    }

    const body = try buildRequestBody(allocator, system_prompt, messages, tools);
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1beta/models/{s}:generateContent",
        .{ proxy_url, model },
    );
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const req_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var req = try client.request(.POST, uri, .{
        .extra_headers = &req_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    // Parse X-RateLimit-* headers BEFORE calling response.reader(),
    // which invalidates the head string pointers.
    var rl_remaining_burst: ?u32 = null;
    var rl_limit_burst: ?u32 = null;
    var rl_remaining_hourly: ?u32 = null;
    var rl_limit_hourly: ?u32 = null;
    var rl_remaining_daily: ?u32 = null;
    var rl_limit_daily: ?u32 = null;

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |header| {
        const val = std.mem.trim(u8, header.value, " ");
        if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining-burst")) {
            rl_remaining_burst = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-limit-burst")) {
            rl_limit_burst = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining-hourly")) {
            rl_remaining_hourly = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-limit-hourly")) {
            rl_limit_hourly = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining-daily")) {
            rl_remaining_daily = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-limit-daily")) {
            rl_limit_daily = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }

    const status = response.head.status;
    // content_encoding is an enum — not affected by head.invalidateStrings()
    const content_encoding = response.head.content_encoding;

    // Allocate decompression buffer before the reader invalidates head strings
    const decompress_buf: []u8 = switch (content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.HttpError,
    };
    defer if (content_encoding != .identity) allocator.free(decompress_buf);

    // Read and decompress response body
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const body_reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    _ = body_reader.streamRemaining(&aw.writer) catch return error.HttpError;
    const resp_body = aw.written();

    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (status == .ok) {
        var chat_response = gemini.parseResponse(allocator, resp_body) catch |err| {
            // Save a copy of the body for later diagnostic output
            last_error_body = allocator.dupe(u8, resp_body) catch null;
            return err;
        };

        // Attach rate limit info when all six headers are present
        if (rl_remaining_burst != null and rl_limit_burst != null and
            rl_remaining_hourly != null and rl_limit_hourly != null and
            rl_remaining_daily != null and rl_limit_daily != null)
        {
            chat_response.rate_limit = .{
                .remaining_burst = rl_remaining_burst.?,
                .limit_burst = rl_limit_burst.?,
                .remaining_hourly = rl_remaining_hourly.?,
                .limit_hourly = rl_limit_hourly.?,
                .remaining_daily = rl_remaining_daily.?,
                .limit_daily = rl_limit_daily.?,
            };
        }

        return chat_response;
    }

    // Clear the spinner line before printing any error
    stderr.writeAll("\r\x1b[K") catch {};

    if (status == .too_many_requests) {
        // Distinguish proxy rate limit (error is string) from upstream Gemini 429 (error is object)
        if (isProxyRateLimitBody(allocator, resp_body)) {
            printProxyRateLimitError(stderr, allocator, resp_body);
            return error.RateLimited;
        }
        // Upstream Gemini API error
        printUpstreamError(stderr, allocator, resp_body, null);
        return error.ApiError;
    }

    // Other HTTP errors
    printUpstreamError(stderr, allocator, resp_body, status);
    return error.ApiError;
}

// ──────────────────────────────────────────────────────────────────
// Internal helpers
// ──────────────────────────────────────────────────────────────────

/// Build the Gemini-format request body (identical to gemini.buildRequestBody).
fn buildRequestBody(
    allocator: Allocator,
    system_prompt: []const u8,
    messages: []const provider.Message,
    tools: []const provider.Tool,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"system_instruction\":{\"parts\":[{\"text\":\"");
    const sys_escaped = try json_helpers.escapeJsonString(allocator, system_prompt);
    defer allocator.free(sys_escaped);
    try w.writeAll(sys_escaped);
    try w.writeAll("\"}]},\"contents\":");

    const contents_json = try json_helpers.buildGeminiContentsJson(allocator, messages);
    defer allocator.free(contents_json);
    try w.writeAll(contents_json);

    if (tools.len > 0) {
        try w.writeAll(",\"tools\":");
        const tools_json = try json_helpers.buildGeminiToolsJson(allocator, tools);
        defer allocator.free(tools_json);
        try w.writeAll(tools_json);
    }

    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

/// Check whether the body is a proxy rate-limit response (error is a string)
/// vs an upstream Gemini error (error is an object).
fn isProxyRateLimitBody(allocator: Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const err = root.get("error") orelse return false;
    return switch (err) {
        .string => true,
        else => false,
    };
}

/// Print the proxy's own rate-limit error.
/// Body format: {"error": "...", "retry_after_seconds": N, "usage": {...}}
fn printProxyRateLimitError(
    stderr: anytype,
    allocator: Allocator,
    body: []const u8,
) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        stderr.writeAll("Rate limit exceeded.\n") catch {};
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            stderr.writeAll("Rate limit exceeded.\n") catch {};
            return;
        },
    };

    const error_msg = if (root.get("error")) |e| switch (e) {
        .string => |s| s,
        else => "Rate limit exceeded.",
    } else "Rate limit exceeded.";

    stderr.print("{s}\n", .{error_msg}) catch {};

    const retry_secs: ?u64 = if (root.get("retry_after_seconds")) |r| switch (r) {
        .integer => |n| if (n > 0) @intCast(n) else null,
        .float => |f| if (f > 0) @intFromFloat(f) else null,
        else => null,
    } else null;

    if (retry_secs) |secs| {
        const h = secs / 3600;
        const m = (secs % 3600) / 60;
        const s = secs % 60;
        if (h > 0) {
            stderr.print("Resets in {d}h {d}m.\n", .{ h, m }) catch {};
        } else if (m > 0) {
            stderr.print("Resets in {d}m.\n", .{m}) catch {};
        } else {
            stderr.print("Resets in {d}s.\n", .{s}) catch {};
        }
    }
}

/// Print an upstream Gemini API error to stderr.
/// Handles Gemini format: {"error": {"message": "..."}}
/// Falls back to raw body if parsing fails.
/// When `status` is non-null, includes the HTTP status code in the prefix.
fn printUpstreamError(
    stderr: anytype,
    allocator: Allocator,
    body: []const u8,
    status: ?std.http.Status,
) void {
    if (body.len == 0) {
        if (status) |s| {
            stderr.print("Gemini API error: HTTP {d}\n", .{@intFromEnum(s)}) catch {};
        } else {
            stderr.writeAll("Gemini API error\n") catch {};
        }
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        if (status) |s| {
            stderr.print("Gemini API error (HTTP {d}): {s}\n", .{ @intFromEnum(s), body }) catch {};
        } else {
            stderr.print("Gemini API error: {s}\n", .{body}) catch {};
        }
        return;
    };
    defer parsed.deinit();

    const msg = blk: {
        const root = switch (parsed.value) {
            .object => |o| o,
            else => break :blk body,
        };
        const err = root.get("error") orelse break :blk body;
        const obj = switch (err) {
            .object => |o| o,
            else => break :blk body,
        };
        const m = obj.get("message") orelse break :blk body;
        break :blk switch (m) {
            .string => |s| s,
            else => body,
        };
    };

    if (status) |s| {
        stderr.print("Gemini API error (HTTP {d}): {s}\n", .{ @intFromEnum(s), msg }) catch {};
    } else {
        stderr.print("Gemini API error: {s}\n", .{msg}) catch {};
    }
}
