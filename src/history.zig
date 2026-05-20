const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single history entry representing one pls session.
pub const HistoryEntry = struct {
    /// ISO 8601 timestamp of when pls was invoked (e.g. "2026-03-30T14:23:00Z")
    timestamp: []const u8,
    /// Working directory when pls was invoked
    cwd: []const u8,
    /// The user's original task message
    task: []const u8,
    /// Shell commands that were actually executed (not dry-run, not declined)
    commands: []const []const u8,
};

/// Free a HistoryEntry returned by loadEntries.
pub fn freeEntry(allocator: Allocator, entry: HistoryEntry) void {
    allocator.free(entry.timestamp);
    allocator.free(entry.cwd);
    allocator.free(entry.task);
    for (entry.commands) |cmd| {
        allocator.free(cmd);
    }
    allocator.free(entry.commands);
}

/// Return an 8-character content-based identifier for a history entry.
pub fn entryShortId(entry: HistoryEntry) [8]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(entry.timestamp);
    hasher.update("\x00");
    hasher.update(entry.cwd);
    hasher.update("\x00");
    hasher.update(entry.task);
    for (entry.commands) |command| {
        hasher.update("\x00");
        hasher.update(command);
    }

    const short: u32 = @truncate(hasher.final());
    const hex = "0123456789abcdef";
    var id: [8]u8 = undefined;
    for (0..id.len) |i| {
        const shift: u5 = @intCast((id.len - 1 - i) * 4);
        const nibble: usize = @intCast((short >> shift) & 0xf);
        id[i] = hex[nibble];
    }
    return id;
}

/// Returns the path to the pls data directory.
/// Uses $XDG_DATA_HOME/pls if set, otherwise ~/.local/share/pls.
/// Caller owns the returned slice.
pub fn getDataDir(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/pls", .{xdg});
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/pls", .{home});
}

/// Returns the full path to the history file.
/// Caller owns the returned slice.
pub fn getHistoryPath(allocator: Allocator) ![]const u8 {
    const dir = try getDataDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{dir});
}

/// Generate the current UTC time as an ISO 8601 string (e.g. "2026-03-30T14:23:45Z").
/// Caller owns the returned slice.
pub fn currentTimestamp(allocator: Allocator) ![]const u8 {
    const secs_i64 = std.time.timestamp();
    if (secs_i64 < 0) return allocator.dupe(u8, "1970-01-01T00:00:00Z");
    const secs: u64 = @intCast(secs_i64);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// Append a history entry to the history file as a JSONL line.
/// Creates the data directory if it doesn't exist.
pub fn appendEntry(allocator: Allocator, entry: HistoryEntry) !void {
    const dir_path = try getDataDir(allocator);
    defer allocator.free(dir_path);

    // Ensure the data directory exists
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_path = try std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{dir_path});
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try writeEntryToFile(allocator, file, entry);
}

/// Serialize a HistoryEntry and write it as a JSON line to an open file.
fn writeEntryToFile(allocator: Allocator, file: std.fs.File, entry: HistoryEntry) !void {
    const EntryJson = struct {
        timestamp: []const u8,
        cwd: []const u8,
        task: []const u8,
        commands: []const []const u8,
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, EntryJson{
        .timestamp = entry.timestamp,
        .cwd = entry.cwd,
        .task = entry.task,
        .commands = entry.commands,
    }, .{});
    defer allocator.free(json_str);

    try file.writeAll(json_str);
    try file.writeAll("\n");
}

/// Load the most recent `limit` history entries from the history file.
/// Returns entries in reverse chronological order (newest first).
/// Caller owns the returned slice and must call freeEntry() on each entry,
/// then free the slice itself.
pub fn loadEntries(allocator: Allocator, limit: usize) ![]HistoryEntry {
    const file_path = try getHistoryPath(allocator);
    defer allocator.free(file_path);

    const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(HistoryEntry, 0),
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    return loadEntriesFromContent(allocator, content, limit);
}

/// Parse JSONL content and return up to `limit` entries, newest first.
fn loadEntriesFromContent(allocator: Allocator, content: []const u8, limit: usize) ![]HistoryEntry {
    var all_entries: std.ArrayList(HistoryEntry) = .empty;
    errdefer {
        for (all_entries.items) |e| freeEntry(allocator, e);
        all_entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const entry = parseEntry(allocator, trimmed) catch continue;
        try all_entries.append(allocator, entry);
    }

    // Select the last `limit` entries
    const total = all_entries.items.len;
    const start = if (total > limit) total - limit else 0;
    const count = total - start;

    // Allocate result slice
    const result = try allocator.alloc(HistoryEntry, count);

    // Fill result in reverse order (newest entry first)
    for (0..count) |i| {
        result[i] = all_entries.items[total - 1 - i];
    }

    // Free entries not included in the result
    for (all_entries.items[0..start]) |e| {
        freeEntry(allocator, e);
    }

    // Free the backing array only (string ownership transferred to result)
    all_entries.deinit(allocator);

    return result;
}

/// Parse a single JSONL line into a HistoryEntry with owned strings.
fn parseEntry(allocator: Allocator, line: []const u8) !HistoryEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFormat,
    };

    const timestamp = if (obj.get("timestamp")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    } else return error.InvalidFormat;
    errdefer allocator.free(timestamp);

    const cwd = if (obj.get("cwd")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    } else return error.InvalidFormat;
    errdefer allocator.free(cwd);

    const task = if (obj.get("task")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    } else return error.InvalidFormat;
    errdefer allocator.free(task);

    var commands: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (commands.items) |cmd| allocator.free(cmd);
        commands.deinit(allocator);
    }

    if (obj.get("commands")) |v| {
        switch (v) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |s| try commands.append(allocator, try allocator.dupe(u8, s)),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return .{
        .timestamp = timestamp,
        .cwd = cwd,
        .task = task,
        .commands = try commands.toOwnedSlice(allocator),
    };
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

test "getDataDir returns path ending with /pls" {
    const allocator = std.testing.allocator;
    const dir = try getDataDir(allocator);
    defer allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/pls"));
}

test "getHistoryPath ends with history.jsonl" {
    const allocator = std.testing.allocator;
    const path = try getHistoryPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/history.jsonl"));
}

test "currentTimestamp returns valid ISO 8601 format" {
    const allocator = std.testing.allocator;
    const ts = try currentTimestamp(allocator);
    defer allocator.free(ts);
    // Expected format: "2026-03-30T14:23:45Z" (exactly 20 chars)
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, '-'), ts[7]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
    try std.testing.expectEqual(@as(u8, ':'), ts[13]);
    try std.testing.expectEqual(@as(u8, ':'), ts[16]);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[19]);
}

test "entryShortId is stable for identical content" {
    const commands = [_][]const u8{ "zig fmt src/", "zig build test" };
    const entry = HistoryEntry{
        .timestamp = "2026-03-30T14:23:00Z",
        .cwd = "/home/user/project",
        .task = "verify changes",
        .commands = &commands,
    };

    const first_id = entryShortId(entry);
    const second_id = entryShortId(entry);
    try std.testing.expectEqualStrings(&first_id, &second_id);
}

test "entryShortId includes timestamp cwd task and commands" {
    const commands = [_][]const u8{"zig build test"};
    const changed_commands = [_][]const u8{"zig build"};
    const base = HistoryEntry{
        .timestamp = "2026-03-30T14:23:00Z",
        .cwd = "/home/user/project",
        .task = "verify changes",
        .commands = &commands,
    };

    const changed_timestamp = HistoryEntry{
        .timestamp = "2026-03-30T14:24:00Z",
        .cwd = base.cwd,
        .task = base.task,
        .commands = base.commands,
    };
    const changed_cwd = HistoryEntry{
        .timestamp = base.timestamp,
        .cwd = "/home/user/other",
        .task = base.task,
        .commands = base.commands,
    };
    const changed_task = HistoryEntry{
        .timestamp = base.timestamp,
        .cwd = base.cwd,
        .task = "build project",
        .commands = base.commands,
    };
    const changed_command = HistoryEntry{
        .timestamp = base.timestamp,
        .cwd = base.cwd,
        .task = base.task,
        .commands = &changed_commands,
    };

    const base_id = entryShortId(base);
    const changed_timestamp_id = entryShortId(changed_timestamp);
    const changed_cwd_id = entryShortId(changed_cwd);
    const changed_task_id = entryShortId(changed_task);
    const changed_command_id = entryShortId(changed_command);
    try std.testing.expect(!std.mem.eql(u8, &base_id, &changed_timestamp_id));
    try std.testing.expect(!std.mem.eql(u8, &base_id, &changed_cwd_id));
    try std.testing.expect(!std.mem.eql(u8, &base_id, &changed_task_id));
    try std.testing.expect(!std.mem.eql(u8, &base_id, &changed_command_id));
}

// ── parseEntry ────────────────────────────────────────────────────

test "parseEntry parses all fields correctly" {
    const allocator = std.testing.allocator;

    const line =
        \\{"timestamp":"2026-03-30T14:23:00Z","cwd":"/home/user/project","task":"stop port 3000","commands":["lsof -ti:3000","kill -9 1234"]}
    ;

    const entry = try parseEntry(allocator, line);
    defer freeEntry(allocator, entry);

    try std.testing.expectEqualStrings("2026-03-30T14:23:00Z", entry.timestamp);
    try std.testing.expectEqualStrings("/home/user/project", entry.cwd);
    try std.testing.expectEqualStrings("stop port 3000", entry.task);
    try std.testing.expectEqual(@as(usize, 2), entry.commands.len);
    try std.testing.expectEqualStrings("lsof -ti:3000", entry.commands[0]);
    try std.testing.expectEqualStrings("kill -9 1234", entry.commands[1]);
}

test "parseEntry handles empty commands array" {
    const allocator = std.testing.allocator;

    const line =
        \\{"timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp","task":"nothing","commands":[]}
    ;

    const entry = try parseEntry(allocator, line);
    defer freeEntry(allocator, entry);

    try std.testing.expectEqual(@as(usize, 0), entry.commands.len);
}

test "parseEntry handles special characters in task and commands" {
    const allocator = std.testing.allocator;

    const line =
        \\{"timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp","task":"find & replace \"quotes\"","commands":["sed -i 's/foo/bar/g' file.txt"]}
    ;

    const entry = try parseEntry(allocator, line);
    defer freeEntry(allocator, entry);

    try std.testing.expectEqualStrings("find & replace \"quotes\"", entry.task);
    try std.testing.expectEqualStrings("sed -i 's/foo/bar/g' file.txt", entry.commands[0]);
}

test "parseEntry returns error for malformed JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.JsonParseError, parseEntry(allocator, "not json at all"));
    try std.testing.expectError(error.JsonParseError, parseEntry(allocator, "{incomplete"));
}

test "parseEntry returns error for missing required fields" {
    const allocator = std.testing.allocator;
    // Missing timestamp
    try std.testing.expectError(error.InvalidFormat, parseEntry(allocator, "{\"cwd\":\"/tmp\",\"task\":\"x\",\"commands\":[]}"));
    // Missing cwd
    try std.testing.expectError(error.InvalidFormat, parseEntry(allocator, "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"task\":\"x\",\"commands\":[]}"));
    // Missing task
    try std.testing.expectError(error.InvalidFormat, parseEntry(allocator, "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"cwd\":\"/tmp\",\"commands\":[]}"));
}

test "parseEntry returns error for JSON array (not object)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidFormat, parseEntry(allocator, "[1,2,3]"));
}

// ── writeEntryToFile ──────────────────────────────────────────────

test "writeEntryToFile produces a valid JSON line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cmds = [_][]const u8{ "ls -la", "echo done" };
    const entry = HistoryEntry{
        .timestamp = "2026-03-30T14:23:00Z",
        .cwd = "/home/user",
        .task = "list files",
        .commands = &cmds,
    };

    {
        const file = try tmp.dir.createFile("history.jsonl", .{});
        defer file.close();
        try writeEntryToFile(allocator, file, entry);
    }

    const content = try tmp.dir.readFileAlloc(allocator, "history.jsonl", 4096);
    defer allocator.free(content);

    // Must be exactly one line ending with newline
    try std.testing.expect(std.mem.endsWith(u8, content, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));

    // Parse it back to verify round-trip
    const trimmed = std.mem.trimRight(u8, content, "\r\n");
    const parsed = try parseEntry(allocator, trimmed);
    defer freeEntry(allocator, parsed);

    try std.testing.expectEqualStrings("2026-03-30T14:23:00Z", parsed.timestamp);
    try std.testing.expectEqualStrings("/home/user", parsed.cwd);
    try std.testing.expectEqualStrings("list files", parsed.task);
    try std.testing.expectEqual(@as(usize, 2), parsed.commands.len);
    try std.testing.expectEqualStrings("ls -la", parsed.commands[0]);
    try std.testing.expectEqualStrings("echo done", parsed.commands[1]);
}

test "writeEntryToFile appends multiple entries as separate lines" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cmds1 = [_][]const u8{"echo first"};
    const cmds2 = [_][]const u8{"echo second"};

    {
        const file = try tmp.dir.createFile("history.jsonl", .{ .truncate = false });
        defer file.close();
        try writeEntryToFile(allocator, file, .{
            .timestamp = "2026-03-30T10:00:00Z",
            .cwd = "/tmp",
            .task = "first task",
            .commands = &cmds1,
        });
        try writeEntryToFile(allocator, file, .{
            .timestamp = "2026-03-30T11:00:00Z",
            .cwd = "/tmp",
            .task = "second task",
            .commands = &cmds2,
        });
    }

    const content = try tmp.dir.readFileAlloc(allocator, "history.jsonl", 4096);
    defer allocator.free(content);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "\n"));
}

// ── loadEntriesFromContent ────────────────────────────────────────

test "loadEntriesFromContent returns empty for empty content" {
    const allocator = std.testing.allocator;
    const entries = try loadEntriesFromContent(allocator, "", 20);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "loadEntriesFromContent returns empty for whitespace-only content" {
    const allocator = std.testing.allocator;
    const entries = try loadEntriesFromContent(allocator, "\n\n  \n", 20);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "loadEntriesFromContent parses single entry" {
    const allocator = std.testing.allocator;

    const content =
        \\{"timestamp":"2026-03-30T14:23:00Z","cwd":"/home/user","task":"do something","commands":["ls"]}
        \\
    ;

    const entries = try loadEntriesFromContent(allocator, content, 20);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("2026-03-30T14:23:00Z", entries[0].timestamp);
    try std.testing.expectEqualStrings("do something", entries[0].task);
    try std.testing.expectEqual(@as(usize, 1), entries[0].commands.len);
    try std.testing.expectEqualStrings("ls", entries[0].commands[0]);
}

test "loadEntriesFromContent returns entries newest first" {
    const allocator = std.testing.allocator;

    // Three entries in chronological order (oldest first in file)
    const content =
        \\{"timestamp":"2026-03-30T08:00:00Z","cwd":"/tmp","task":"first","commands":[]}
        \\{"timestamp":"2026-03-30T09:00:00Z","cwd":"/tmp","task":"second","commands":[]}
        \\{"timestamp":"2026-03-30T10:00:00Z","cwd":"/tmp","task":"third","commands":[]}
        \\
    ;

    const entries = try loadEntriesFromContent(allocator, content, 20);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // Newest first
    try std.testing.expectEqualStrings("third", entries[0].task);
    try std.testing.expectEqualStrings("second", entries[1].task);
    try std.testing.expectEqualStrings("first", entries[2].task);
}

test "loadEntriesFromContent respects limit — returns only the newest N" {
    const allocator = std.testing.allocator;

    const content =
        \\{"timestamp":"2026-03-30T08:00:00Z","cwd":"/tmp","task":"first","commands":[]}
        \\{"timestamp":"2026-03-30T09:00:00Z","cwd":"/tmp","task":"second","commands":[]}
        \\{"timestamp":"2026-03-30T10:00:00Z","cwd":"/tmp","task":"third","commands":[]}
        \\{"timestamp":"2026-03-30T11:00:00Z","cwd":"/tmp","task":"fourth","commands":[]}
        \\{"timestamp":"2026-03-30T12:00:00Z","cwd":"/tmp","task":"fifth","commands":[]}
        \\
    ;

    const entries = try loadEntriesFromContent(allocator, content, 3);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("fifth", entries[0].task);
    try std.testing.expectEqualStrings("fourth", entries[1].task);
    try std.testing.expectEqualStrings("third", entries[2].task);
}

test "loadEntriesFromContent with limit larger than entry count returns all" {
    const allocator = std.testing.allocator;

    const content =
        \\{"timestamp":"2026-03-30T08:00:00Z","cwd":"/tmp","task":"only one","commands":[]}
        \\
    ;

    const entries = try loadEntriesFromContent(allocator, content, 100);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
}

test "loadEntriesFromContent skips malformed lines without error" {
    const allocator = std.testing.allocator;

    const content =
        \\{"timestamp":"2026-03-30T08:00:00Z","cwd":"/tmp","task":"good first","commands":[]}
        \\{this is not valid json
        \\just a plain string
        \\{"timestamp":"2026-03-30T10:00:00Z","cwd":"/tmp","task":"good third","commands":[]}
        \\
    ;

    const entries = try loadEntriesFromContent(allocator, content, 20);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    // Only the two valid lines should be included
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("good third", entries[0].task);
    try std.testing.expectEqualStrings("good first", entries[1].task);
}

// ── writeEntryToFile + loadEntriesFromContent round-trip ──────────

test "writeEntryToFile and loadEntriesFromContent full round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cmds_a = [_][]const u8{ "git status", "git add ." };
    const cmds_b = [_][]const u8{"cargo build --release"};

    // Write two entries to file
    {
        const file = try tmp.dir.createFile("history.jsonl", .{ .truncate = false });
        defer file.close();
        try writeEntryToFile(allocator, file, .{
            .timestamp = "2026-03-30T09:00:00Z",
            .cwd = "/home/user/myrepo",
            .task = "check git status and stage",
            .commands = &cmds_a,
        });
        try writeEntryToFile(allocator, file, .{
            .timestamp = "2026-03-30T10:00:00Z",
            .cwd = "/home/user/myproject",
            .task = "build release",
            .commands = &cmds_b,
        });
    }

    // Read content and parse
    const content = try tmp.dir.readFileAlloc(allocator, "history.jsonl", 4096);
    defer allocator.free(content);

    const entries = try loadEntriesFromContent(allocator, content, 20);
    defer {
        for (entries) |e| freeEntry(allocator, e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Newest first
    try std.testing.expectEqualStrings("build release", entries[0].task);
    try std.testing.expectEqualStrings("/home/user/myproject", entries[0].cwd);
    try std.testing.expectEqual(@as(usize, 1), entries[0].commands.len);
    try std.testing.expectEqualStrings("cargo build --release", entries[0].commands[0]);

    try std.testing.expectEqualStrings("check git status and stage", entries[1].task);
    try std.testing.expectEqualStrings("/home/user/myrepo", entries[1].cwd);
    try std.testing.expectEqual(@as(usize, 2), entries[1].commands.len);
    try std.testing.expectEqualStrings("git status", entries[1].commands[0]);
    try std.testing.expectEqualStrings("git add .", entries[1].commands[1]);
}
