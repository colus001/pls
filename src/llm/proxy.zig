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

    if (status == .service_unavailable) {
        // Proxy budget exceeded: body is {"error": "string"} from the proxy itself
        if (isProxyRateLimitBody(allocator, resp_body)) {
            printProxyBudgetError(stderr, allocator, resp_body);
            return error.BudgetExceeded;
        }
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

/// Print the proxy's budget-exceeded error.
/// Body format: {"error": "..."} (same structure as rate-limit but no retry_after_seconds)
fn printProxyBudgetError(
    stderr: anytype,
    allocator: Allocator,
    body: []const u8,
) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        stderr.writeAll("Proxy budget limit exceeded. Service temporarily unavailable.\n") catch {};
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            stderr.writeAll("Proxy budget limit exceeded. Service temporarily unavailable.\n") catch {};
            return;
        },
    };

    const error_msg = if (root.get("error")) |e| switch (e) {
        .string => |s| s,
        else => "Proxy budget limit exceeded. Service temporarily unavailable.",
    } else "Proxy budget limit exceeded. Service temporarily unavailable.";

    stderr.print("{s}\n", .{error_msg}) catch {};
}

/// Print an upstream Gemini API error to stderr.
/// Handles Gemini format: {"error": {"message": "..."}}
/// Falls back to raw body if parsing fails.
/// When `status` is non-null, includes the HTTP status code in the prefix.
pub fn printUpstreamError(
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

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

/// Context passed to the mock HTTP server thread.
const MockServeCtx = struct {
    server: *std.net.Server,
    /// HTTP status text, e.g. "200 OK" or "429 Too Many Requests"
    status: []const u8,
    /// Zero or more extra header lines, each ending with \r\n
    extra_headers: []const u8,
    /// Response body bytes
    body: []const u8,
};

/// Read and discard a complete HTTP/1.1 request from `stream` so the
/// client does not get a broken-pipe while still writing its body.
fn drainHttpRequest(stream: std.net.Stream) void {
    var buf: [65536]u8 = undefined;
    var total: usize = 0;

    // Read until end-of-headers marker "\r\n\r\n".
    const header_end: usize = found: {
        while (total < buf.len) {
            const n = stream.read(buf[total..]) catch return;
            if (n == 0) return;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |pos| break :found pos + 4;
        }
        return;
    };

    // Parse Content-Length to know how many body bytes follow.
    var content_length: usize = 0;
    var header_it = std.mem.splitSequence(u8, buf[0..header_end], "\r\n");
    while (header_it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
            break;
        }
    }

    // Read any body bytes not yet in the buffer.
    var body_read = total - header_end;
    while (body_read < content_length and total < buf.len) {
        const n = stream.read(buf[total..]) catch return;
        if (n == 0) return;
        total += n;
        body_read += n;
    }
}

/// Accept one connection, drain the request, send the mock response.
/// Designed to run in a `std.Thread` alongside the test calling `chat()`.
fn mockServeOne(ctx: *const MockServeCtx) void {
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    drainHttpRequest(conn.stream);

    // Build the full HTTP response in a stack buffer.
    var resp_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&resp_buf);
    const w = fbs.writer();
    w.print("HTTP/1.1 {s}\r\n", .{ctx.status}) catch return;
    w.writeAll("Content-Type: application/json\r\n") catch return;
    w.print("Content-Length: {d}\r\n", .{ctx.body.len}) catch return;
    w.writeAll("Connection: close\r\n") catch return;
    if (ctx.extra_headers.len > 0) {
        w.writeAll(ctx.extra_headers) catch return;
    }
    w.writeAll("\r\n") catch return;
    w.writeAll(ctx.body) catch return;

    conn.stream.writeAll(fbs.getWritten()) catch return;
}

/// Create a single-element user message slice for use in integration tests.
fn testMessages(allocator: Allocator) ![]provider.Message {
    const msgs = try allocator.alloc(provider.Message, 1);
    msgs[0] = try provider.Message.text(allocator, .user, "hello");
    return msgs;
}

fn freeTestMessages(allocator: Allocator, msgs: []provider.Message) void {
    for (msgs) |*m| m.deinit(allocator);
    allocator.free(msgs);
}

// ---- Unit tests ---------------------------------------------------

test "isProxyRateLimitBody detects proxy error string" {
    try std.testing.expect(isProxyRateLimitBody(
        std.testing.allocator,
        \\{"error":"Too many requests. Please wait a moment."}
        ,
    ));
}

test "isProxyRateLimitBody rejects upstream error object" {
    try std.testing.expect(!isProxyRateLimitBody(
        std.testing.allocator,
        \\{"error":{"code":429,"message":"Quota exceeded"}}
        ,
    ));
}

test "isProxyRateLimitBody rejects invalid JSON" {
    try std.testing.expect(!isProxyRateLimitBody(std.testing.allocator, "not json"));
}

test "isProxyRateLimitBody rejects missing error field" {
    try std.testing.expect(!isProxyRateLimitBody(
        std.testing.allocator,
        \\{"message":"something else"}
        ,
    ));
}

test "printProxyRateLimitError formats message with minutes retry" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printProxyRateLimitError(fbs.writer(), std.testing.allocator,
        \\{"error":"Too many requests. Please wait a moment.","retry_after_seconds":300}
    );
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Too many requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "5m") != null);
}

test "printProxyRateLimitError formats message with hours retry" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printProxyRateLimitError(fbs.writer(), std.testing.allocator,
        \\{"error":"Daily limit reached.","retry_after_seconds":7200}
    );
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Daily limit reached.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2h") != null);
}

test "printProxyRateLimitError omits reset time when not provided" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printProxyRateLimitError(fbs.writer(), std.testing.allocator,
        \\{"error":"Hourly limit reached."}
    );
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hourly limit reached.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Resets") == null);
}

test "printProxyBudgetError formats error message from body" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printProxyBudgetError(fbs.writer(), std.testing.allocator,
        \\{"error":"Service temporarily unavailable. Please try again later.","code":"SERVICE_UNAVAILABLE"}
    );
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Service temporarily unavailable") != null);
}

test "printProxyBudgetError falls back on invalid JSON" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printProxyBudgetError(fbs.writer(), std.testing.allocator, "bad json");
    const out = fbs.getWritten();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "unavailable") != null);
}

// ---- Integration tests --------------------------------------------

test "chat returns ChatResponse on 200" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "200 OK",
        .extra_headers = "",
        .body =
        \\{"candidates":[{"content":{"parts":[{"text":"Hello!"}],"role":"model"},"finishReason":"STOP"}]}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    var resp = try chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    defer resp.deinit(a);

    try std.testing.expectEqualStrings("Hello!", resp.message.getText().?);
    try std.testing.expectEqual(provider.StopReason.end_turn, resp.stop_reason);
    try std.testing.expect(resp.rate_limit == null);
}

test "chat populates rate_limit from response headers" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "200 OK",
        .extra_headers = "X-RateLimit-Remaining-Burst: 14\r\n" ++
            "X-RateLimit-Limit-Burst: 15\r\n" ++
            "X-RateLimit-Remaining-Hourly: 74\r\n" ++
            "X-RateLimit-Limit-Hourly: 75\r\n" ++
            "X-RateLimit-Remaining-Daily: 149\r\n" ++
            "X-RateLimit-Limit-Daily: 150\r\n",
        .body =
        \\{"candidates":[{"content":{"parts":[{"text":"Hi"}],"role":"model"},"finishReason":"STOP"}]}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    var resp = try chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    defer resp.deinit(a);

    try std.testing.expect(resp.rate_limit != null);
    const rl = resp.rate_limit.?;
    try std.testing.expectEqual(@as(u32, 14), rl.remaining_burst);
    try std.testing.expectEqual(@as(u32, 15), rl.limit_burst);
    try std.testing.expectEqual(@as(u32, 74), rl.remaining_hourly);
    try std.testing.expectEqual(@as(u32, 75), rl.limit_hourly);
    try std.testing.expectEqual(@as(u32, 149), rl.remaining_daily);
    try std.testing.expectEqual(@as(u32, 150), rl.limit_daily);
}

test "chat returns error.RateLimited on proxy 429" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "429 Too Many Requests",
        .extra_headers = "",
        .body =
        \\{"error":"Too many requests. Please wait a moment.","retry_after_seconds":60}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    const result = chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    try std.testing.expectError(error.RateLimited, result);
}

test "chat returns error.ApiError on upstream-format 429" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "429 Too Many Requests",
        .extra_headers = "",
        .body =
        \\{"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    const result = chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    try std.testing.expectError(error.ApiError, result);
}

test "chat returns error.BudgetExceeded on proxy 503" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "503 Service Unavailable",
        .extra_headers = "",
        .body =
        \\{"error":"Service temporarily unavailable. Please try again later.","code":"SERVICE_UNAVAILABLE"}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    const result = chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    try std.testing.expectError(error.BudgetExceeded, result);
}

test "chat returns error.ApiError on upstream-format 503" {
    const a = std.testing.allocator;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try addr.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    const proxy_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{net_server.listen_address.getPort()});
    defer a.free(proxy_url);

    const serve_ctx: MockServeCtx = .{
        .server = &net_server,
        .status = "503 Service Unavailable",
        .extra_headers = "",
        .body =
        \\{"error":{"code":503,"message":"Service temporarily unavailable","status":"UNAVAILABLE"}}
        ,
    };
    const thread = try std.Thread.spawn(.{}, mockServeOne, .{&serve_ctx});
    defer thread.join();

    const msgs = try testMessages(a);
    defer freeTestMessages(a, msgs);

    const result = chat(a, "gemini-2.5-flash-lite", "You are helpful.", msgs, &.{}, proxy_url);
    try std.testing.expectError(error.ApiError, result);
}
