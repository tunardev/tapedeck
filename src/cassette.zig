//! On-disk cassette format: JSON Lines, one exchange per line, sorted by key.

const std = @import("std");
const Io = std.Io;

/// A recorded body.
///
/// Text is preferred so a cassette diffs readably in a pull request, but a
/// response with one invalid UTF-8 sequence must still round-trip whole. This
/// is the reason the body is never read as a string.
pub const Body = union(enum) {
    text: []const u8,
    base64: []const u8,

    /// Caller owns the returned body's memory.
    pub fn fromBytes(gpa: std.mem.Allocator, raw: []const u8) !Body {
        if (std.unicode.utf8ValidateSlice(raw)) {
            return .{ .text = try gpa.dupe(u8, raw) };
        }
        const enc = std.base64.standard.Encoder;
        const buf = try gpa.alloc(u8, enc.calcSize(raw.len));
        return .{ .base64 = enc.encode(buf, raw) };
    }

    /// Caller owns the returned slice.
    pub fn toBytes(b: Body, gpa: std.mem.Allocator) ![]u8 {
        return switch (b) {
            .text => |t| gpa.dupe(u8, t),
            .base64 => |e| blk: {
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(e) catch break :blk gpa.dupe(u8, "");
                const out = try gpa.alloc(u8, n);
                dec.decode(out, e) catch {
                    gpa.free(out);
                    break :blk gpa.dupe(u8, "");
                };
                break :blk out;
            },
        };
    }

    pub fn deinit(b: Body, gpa: std.mem.Allocator) void {
        switch (b) {
            .text, .base64 => |s| gpa.free(s),
        }
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// One recorded request/response pair.
pub const Exchange = struct {
    key: []const u8,
    status: u16,
    headers: []const Header,
    body: Body,
    /// Recorded without a content-length. Absent in cassettes written before
    /// this field existed, which load as false.
    chunked: bool = false,
    /// Tokens the provider reported. Zero when it reported none, and absent
    /// in cassettes written before these fields existed.
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// Model the provider named, for pricing. Owned like the other strings.
    model: []const u8 = "",

    pub fn deinit(e: Exchange, gpa: std.mem.Allocator) void {
        gpa.free(e.key);
        for (e.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(e.headers);
        gpa.free(e.model);
        e.body.deinit(gpa);
    }
};

/// A cassette file loaded into memory.
pub const Cassette = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    entries: std.StringArrayHashMapUnmanaged(Exchange),
    dirty: bool,

    /// A missing file is an empty cassette, not an error: the first run of a
    /// new test suite has nothing recorded yet.
    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Cassette {
        var c: Cassette = .{
            .gpa = gpa,
            .path = try gpa.dupe(u8, path),
            .entries = .empty,
            .dirty = false,
        };
        errdefer c.deinit();

        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return c,
            else => return e,
        };
        defer gpa.free(text);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            const e = try parseLine(gpa, line);
            try c.entries.put(gpa, e.key, e);
        }
        return c;
    }

    pub fn deinit(c: *Cassette) void {
        for (c.entries.values()) |e| e.deinit(c.gpa);
        c.entries.deinit(c.gpa);
        c.gpa.free(c.path);
    }

    pub fn get(c: *const Cassette, key: []const u8) ?Exchange {
        return c.entries.get(key);
    }

    pub fn count(c: *const Cassette) usize {
        return c.entries.count();
    }

    /// Entries in stored order. Callers must not free what they see.
    pub fn values(c: *const Cassette) []const Exchange {
        return c.entries.values();
    }

    /// Takes ownership of `e`; replaces any entry with the same key.
    pub fn insert(c: *Cassette, e: Exchange) !void {
        if (c.entries.fetchSwapRemove(e.key)) |old| old.value.deinit(c.gpa);
        try c.entries.put(c.gpa, e.key, e);
        c.dirty = true;
    }

    /// Write via a temporary file and rename, so an interrupted run leaves the
    /// previous cassette intact rather than a truncated one.
    pub fn save(c: *Cassette, io: Io) !void {
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(c.path)) |parent| {
            try cwd.createDirPath(io, parent);
        }

        // Sorted so a re-record produces a minimal diff rather than a reshuffle.
        const keys = try c.gpa.alloc([]const u8, c.entries.count());
        defer c.gpa.free(keys);
        for (c.entries.keys(), 0..) |k, i| keys[i] = k;
        std.mem.sortUnstable([]const u8, keys, {}, lessThanSlice);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(c.gpa);
        for (keys) |k| {
            try writeLine(c.gpa, c.entries.get(k).?, &out);
            try out.append(c.gpa, '\n');
        }

        const tmp = try std.fmt.allocPrint(c.gpa, "{s}.tmp", .{c.path});
        defer c.gpa.free(tmp);

        {
            const f = try cwd.createFile(io, tmp, .{ .truncate = true });
            defer f.close(io);
            var buf: [4096]u8 = undefined;
            var w = f.writer(io, &buf);
            try w.interface.writeAll(out.items);
            try w.interface.flush();
        }
        try Io.Dir.rename(cwd, tmp, cwd, c.path, io);
        c.dirty = false;
    }
};

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn writeLine(gpa: std.mem.Allocator, e: Exchange, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, "{\"key\":");
    try writeJsonString(gpa, e.key, out);
    var num: [8]u8 = undefined;
    try out.appendSlice(gpa, ",\"status\":");
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num, "{d}", .{e.status}));
    try out.appendSlice(gpa, ",\"headers\":[");
    for (e.headers, 0..) |h, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"name\":");
        try writeJsonString(gpa, h.name, out);
        try out.appendSlice(gpa, ",\"value\":");
        try writeJsonString(gpa, h.value, out);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "],\"input_tokens\":");
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num, "{d}", .{e.input_tokens}));
    try out.appendSlice(gpa, ",\"output_tokens\":");
    var num2: [24]u8 = undefined;
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num2, "{d}", .{e.output_tokens}));
    try out.appendSlice(gpa, ",\"model\":");
    try writeJsonString(gpa, e.model, out);
    try out.appendSlice(gpa, ",\"chunked\":");
    try out.appendSlice(gpa, if (e.chunked) "true" else "false");
    try out.appendSlice(gpa, ",\"encoding\":");
    switch (e.body) {
        .text => |t| {
            try out.appendSlice(gpa, "\"text\",\"body\":");
            try writeJsonString(gpa, t, out);
        },
        .base64 => |b| {
            try out.appendSlice(gpa, "\"base64\",\"body\":");
            try writeJsonString(gpa, b, out);
        },
    }
    try out.append(gpa, '}');
}

fn writeJsonString(gpa: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => {
            if (c < 0x20) {
                var esc: [6]u8 = undefined;
                try out.appendSlice(gpa, try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}));
            } else {
                try out.append(gpa, c);
            }
        },
    };
    try out.append(gpa, '"');
}

fn parseLine(gpa: std.mem.Allocator, line: []const u8) !Exchange {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const key = try gpa.dupe(u8, obj.get("key").?.string);
    errdefer gpa.free(key);
    const status: u16 = @intCast(obj.get("status").?.integer);

    const raw_headers = obj.get("headers").?.array;
    const headers = try gpa.alloc(Header, raw_headers.items.len);
    errdefer gpa.free(headers);
    for (raw_headers.items, 0..) |h, i| {
        headers[i] = .{
            .name = try gpa.dupe(u8, h.object.get("name").?.string),
            .value = try gpa.dupe(u8, h.object.get("value").?.string),
        };
    }

    const payload = obj.get("body").?.string;
    const body: Body = if (std.mem.eql(u8, obj.get("encoding").?.string, "text"))
        .{ .text = try gpa.dupe(u8, payload) }
    else
        .{ .base64 = try gpa.dupe(u8, payload) };

    const chunked = if (obj.get("chunked")) |v| v.bool else false;
    const input_tokens: u64 = if (obj.get("input_tokens")) |v| @intCast(v.integer) else 0;
    const output_tokens: u64 = if (obj.get("output_tokens")) |v| @intCast(v.integer) else 0;
    const model = if (obj.get("model")) |v|
        try gpa.dupe(u8, v.string)
    else
        try gpa.dupe(u8, "");
    return .{
        .key = key,
        .status = status,
        .headers = headers,
        .body = body,
        .chunked = chunked,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .model = model,
    };
}

const testing = std.testing;

fn testExchange(gpa: std.mem.Allocator, key: []const u8, body: []const u8) !Exchange {
    const headers = try gpa.alloc(Header, 1);
    headers[0] = .{
        .name = try gpa.dupe(u8, "content-type"),
        .value = try gpa.dupe(u8, "text/event-stream"),
    };
    return .{
        .key = try gpa.dupe(u8, key),
        .status = 200,
        .headers = headers,
        .body = try Body.fromBytes(gpa, body),
        .model = try gpa.dupe(u8, "test-model"),
        .input_tokens = 3,
        .output_tokens = 4,
    };
}

test "usage survives a save and load" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-usage";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try c.insert(try testExchange(testing.allocator, "k", "body"));
    try c.save(io);

    var reloaded = try Cassette.load(testing.allocator, io, path);
    defer reloaded.deinit();
    const e = reloaded.get("k").?;
    try testing.expectEqual(@as(u64, 3), e.input_tokens);
    try testing.expectEqual(@as(u64, 4), e.output_tokens);
    try testing.expectEqualStrings("test-model", e.model);
}

test "utf8 body is stored as readable text" {
    const b = try Body.fromBytes(testing.allocator, "data: {\"text\":\"hi\"}\n\n");
    defer b.deinit(testing.allocator);
    try testing.expect(b == .text);
}

test "non utf8 body survives a round trip" {
    const raw = [_]u8{ 0x00, 0xff, 0xfe, 0x41 };
    const b = try Body.fromBytes(testing.allocator, &raw);
    defer b.deinit(testing.allocator);
    try testing.expect(b == .base64);
    const back = try b.toBytes(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &raw, back);
}

test "utf8 body survives a round trip" {
    const raw = "event: message_stop\ndata: {}\n\n";
    const b = try Body.fromBytes(testing.allocator, raw);
    defer b.deinit(testing.allocator);
    const back = try b.toBytes(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(raw, back);
}

/// Tests need a real `Io`; `Threaded` is the blocking one.
fn testIo(t: *Io.Threaded) Io {
    t.* = .init(testing.allocator, .{});
    return t.io();
}

test "saved cassette reloads with the same entries" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-a";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.count());

    try c.insert(try testExchange(testing.allocator, "key-a", "first"));
    try c.insert(try testExchange(testing.allocator, "key-b", &[_]u8{ 0xff, 0x00 }));
    try c.save(io);

    var reloaded = try Cassette.load(testing.allocator, io, path);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 2), reloaded.count());

    const a = try reloaded.get("key-a").?.body.toBytes(testing.allocator);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("first", a);

    const b = try reloaded.get("key-b").?.body.toBytes(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x00 }, b);

    try testing.expect(reloaded.get("key-missing") == null);
}

test "entries are written in key order so diffs stay stable" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-b";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try c.insert(try testExchange(testing.allocator, "zzz", "z"));
    try c.insert(try testExchange(testing.allocator, "aaa", "a"));
    try c.save(io);

    const text = try Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(65536));
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "aaa") != null);
}

test "reinserting a key replaces rather than duplicates" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-c";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try c.insert(try testExchange(testing.allocator, "k", "old"));
    try c.insert(try testExchange(testing.allocator, "k", "new"));
    try c.save(io);

    var reloaded = try Cassette.load(testing.allocator, io, path);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 1), reloaded.count());
    const v = try reloaded.get("k").?.body.toBytes(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("new", v);
}

test "save leaves no temporary file behind" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-d";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try c.insert(try testExchange(testing.allocator, "k", "v"));
    try c.save(io);

    const tmp = dir ++ "/cassettes/default.jsonl.tmp";
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, tmp, .{}));
}

test "headers round trip including awkward characters" {
    var t: Io.Threaded = undefined;
    const io = testIo(&t);
    defer t.deinit();

    const dir = ".tapedeck-test-e";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try c.insert(try testExchange(testing.allocator, "quote\"and\\slash\nnewline", "body"));
    try c.save(io);

    var reloaded = try Cassette.load(testing.allocator, io, path);
    defer reloaded.deinit();
    try testing.expect(reloaded.get("quote\"and\\slash\nnewline") != null);
}
