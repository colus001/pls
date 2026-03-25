const std = @import("std");
const Allocator = std.mem.Allocator;

/// Simple HTTP GET helper wrapping std.http.Client.
/// Returns the response body as an owned slice.
pub fn get(
    allocator: Allocator,
    url: []const u8,
    headers: []const std.http.Header,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = headers,
        .response_writer = &aw.writer,
    }) catch {
        return error.HttpError;
    };

    if (result.status != .ok) {
        const err_body = aw.written();
        const stderr = std.fs.File.stderr().deprecatedWriter();
        if (err_body.len > 0) {
            stderr.print("API error (HTTP {d}): {s}\n", .{
                @intFromEnum(result.status),
                err_body,
            }) catch {};
        } else {
            stderr.print("API error: HTTP {d}\n", .{@intFromEnum(result.status)}) catch {};
        }
        return error.ApiError;
    }

    // Return owned copy
    return allocator.dupe(u8, aw.written());
}

/// Simple HTTP DELETE helper wrapping std.http.Client.
/// Returns the response body as an owned slice.
pub fn delete(
    allocator: Allocator,
    url: []const u8,
    headers: []const std.http.Header,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .DELETE,
        .extra_headers = headers,
        .response_writer = &aw.writer,
    }) catch {
        return error.HttpError;
    };

    if (result.status != .ok) {
        const err_body = aw.written();
        const stderr = std.fs.File.stderr().deprecatedWriter();
        if (err_body.len > 0) {
            stderr.print("API error (HTTP {d}): {s}\n", .{
                @intFromEnum(result.status),
                err_body,
            }) catch {};
        } else {
            stderr.print("API error: HTTP {d}\n", .{@intFromEnum(result.status)}) catch {};
        }
        return error.ApiError;
    }

    // Return owned copy
    return allocator.dupe(u8, aw.written());
}

/// Simple HTTP POST helper wrapping std.http.Client.
/// Returns the response body as an owned slice.
pub fn post(
    allocator: Allocator,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &aw.writer,
    }) catch {
        return error.HttpError;
    };

    if (result.status != .ok) {
        const err_body = aw.written();
        const stderr = std.fs.File.stderr().deprecatedWriter();
        if (err_body.len > 0) {
            stderr.print("API error (HTTP {d}): {s}\n", .{
                @intFromEnum(result.status),
                err_body,
            }) catch {};
        } else {
            stderr.print("API error: HTTP {d}\n", .{@intFromEnum(result.status)}) catch {};
        }
        return error.ApiError;
    }

    // Return owned copy
    return allocator.dupe(u8, aw.written());
}
