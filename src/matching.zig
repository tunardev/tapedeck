const std = @import("std");

pub const Scrubber = enum { timestamp, uuid, home_dir };

pub const all_scrubbers = [_]Scrubber{ .timestamp, .uuid, .home_dir };

pub const Target = struct {
    method: []const u8 = "POST",
    provider: []const u8 = "",
    path: []const u8 = "",
};

pub const Options = struct {
    scrubbers: []const Scrubber = &all_scrubbers,
    ignore: []const []const u8 = &.{},
};

pub fn key(
    gpa: std.mem.Allocator,
    target: Target,
    body: []const u8,
    options: Options,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try writeScalar(gpa, &out, 'm', target.method, &.{});
    try writeScalar(gpa, &out, 'p', target.provider, &.{});
    try writePath(gpa, &out, target.path);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            const hex = try gpa.alloc(u8, body.len * 2);
            defer gpa.free(hex);
            _ = std.fmt.bufPrint(hex, "{x}", .{body}) catch unreachable;
            try writeScalar(gpa, &out, 'r', hex, &.{});
            return out.toOwnedSlice(gpa);
        },
    };
    defer parsed.deinit();

    try out.append(gpa, 'j');
    try writeValue(gpa, &out, parsed.value, "", options);
    return out.toOwnedSlice(gpa);
}

fn writePath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    const split = std.mem.indexOfScalar(u8, path, '?');
    try writeScalar(gpa, out, 'u', if (split) |i| path[0..i] else path, &.{});

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.splitScalar(u8, if (split) |i| path[i + 1 ..] else "", '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try names.append(gpa, pair[0..eq]);
    }
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);

    try writeCount(gpa, out, 'q', names.items.len);
    for (names.items) |name| try writeScalar(gpa, out, 'k', name, &.{});
}

fn writeValue(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    v: std.json.Value,
    prefix: []const u8,
    options: Options,
) error{OutOfMemory}!void {
    switch (v) {
        .null => try out.append(gpa, 'z'),
        .bool => |b| try out.append(gpa, if (b) 't' else 'f'),
        .integer => |n| {
            var buf: [24]u8 = undefined;
            try writeScalar(gpa, out, 'n', std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable, &.{});
        },
        .float => |f| {
            var buf: [347]u8 = undefined;
            const text = if (f == @trunc(f) and @abs(f) < 9007199254740992.0) blk: {
                const as_int: i64 = @intFromFloat(f);
                break :blk std.fmt.bufPrint(&buf, "{d}", .{as_int}) catch unreachable;
            } else std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try writeScalar(gpa, out, 'n', text, &.{});
        },
        .number_string => |s| try writeScalar(gpa, out, 'n', s, &.{}),
        .string => |s| try writeScalar(gpa, out, 's', s, options.scrubbers),
        .array => |items| {
            try writeCount(gpa, out, 'a', items.items.len);
            for (items.items) |item| try writeValue(gpa, out, item, prefix, options);
        },
        .object => |obj| {
            const names = try gpa.alloc([]const u8, obj.count());
            defer gpa.free(names);
            var kept: usize = 0;
            for (obj.keys()) |name| {
                if (isIgnored(prefix, name, options.ignore)) continue;
                names[kept] = name;
                kept += 1;
            }
            std.mem.sortUnstable([]const u8, names[0..kept], {}, lessThan);

            try writeCount(gpa, out, 'o', kept);
            for (names[0..kept]) |name| {
                try writeScalar(gpa, out, 'k', name, &.{});
                if (options.ignore.len == 0) {
                    try writeValue(gpa, out, obj.get(name).?, "", options);
                    continue;
                }
                const child = if (prefix.len == 0)
                    try gpa.dupe(u8, name)
                else
                    try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, name });
                defer gpa.free(child);
                try writeValue(gpa, out, obj.get(name).?, child, options);
            }
        },
    }
}

fn writeCount(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tag: u8, n: usize) !void {
    try out.print(gpa, "{c}{d}:", .{ tag, n });
}

fn writeScalar(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: u8,
    text: []const u8,
    scrubbers: []const Scrubber,
) !void {
    var scrubbed: std.ArrayList(u8) = .empty;
    defer scrubbed.deinit(gpa);
    try scrub(gpa, &scrubbed, text, scrubbers);

    try out.print(gpa, "{c}{d}:", .{ tag, scrubbed.items.len });
    try out.appendSlice(gpa, scrubbed.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn isIgnored(prefix: []const u8, name: []const u8, ignore: []const []const u8) bool {
    for (ignore) |path| {
        if (prefix.len == 0) {
            if (std.mem.eql(u8, path, name)) return true;
            continue;
        }
        if (path.len != prefix.len + 1 + name.len) continue;
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        if (path[prefix.len] != '.') continue;
        if (std.mem.eql(u8, path[prefix.len + 1 ..], name)) return true;
    }
    return false;
}

fn scrub(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    scrubbers: []const Scrubber,
) !void {
    if (scrubbers.len == 0) {
        try out.appendSlice(gpa, text);
        return;
    }
    var i: usize = 0;
    outer: while (i < text.len) {
        const prev: ?u8 = if (i == 0) null else text[i - 1];
        for (scrubbers) |s| {
            if (matchLen(s, text[i..], prev)) |n| {
                try out.appendSlice(gpa, placeholder(s));
                i += n;
                continue :outer;
            }
        }
        if (text[i] == '<') try out.append(gpa, '<');
        try out.append(gpa, text[i]);
        i += 1;
    }
}

fn placeholder(s: Scrubber) []const u8 {
    return switch (s) {
        .timestamp => "<TIME>",
        .uuid => "<UUID>",
        .home_dir => "<HOME>",
    };
}

fn matchLen(s: Scrubber, text: []const u8, prev: ?u8) ?usize {
    return switch (s) {
        .timestamp => matchTimestamp(text, prev),
        .uuid => matchUuid(text, prev),
        .home_dir => matchHomeDir(text),
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isBoundary(prev: ?u8) bool {
    const c = prev orelse return true;
    return !(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.');
}

fn twoDigits(text: []const u8, at: usize) ?u8 {
    if (!isDigit(text[at]) or !isDigit(text[at + 1])) return null;
    return (text[at] - '0') * 10 + (text[at + 1] - '0');
}

fn matchTimestamp(text: []const u8, prev: ?u8) ?usize {
    if (!isBoundary(prev) or text.len < 10) return null;
    for (0..4) |i| {
        if (!isDigit(text[i])) return null;
    }
    if (text[4] != '-' or text[7] != '-') return null;
    const month = twoDigits(text, 5) orelse return null;
    const day = twoDigits(text, 8) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    if (text.len < 19 or (text[10] != 'T' and text[10] != ' ')) {
        if (text.len > 10 and (std.ascii.isAlphanumeric(text[10]) or text[10] == '-')) return null;
        return 10;
    }
    const has_time = isDigit(text[11]) and isDigit(text[12]) and text[13] == ':' and
        isDigit(text[14]) and isDigit(text[15]) and text[16] == ':' and
        isDigit(text[17]) and isDigit(text[18]);
    if (!has_time) return 10;

    var n: usize = 19;
    while (n < text.len and (text[n] == 'Z' or text[n] == '.' or isDigit(text[n]))) n += 1;
    return n;
}

fn matchUuid(text: []const u8, prev: ?u8) ?usize {
    const len = 36;
    if (!isBoundary(prev) or text.len < len) return null;
    for (text[0..len], 0..) |c, i| {
        const ok = switch (i) {
            8, 13, 18, 23 => c == '-',
            else => isHex(c),
        };
        if (!ok) return null;
    }
    if (text.len > len and (isHex(text[len]) or text[len] == '-')) return null;
    return len;
}

fn matchHomeDir(text: []const u8) ?usize {
    for ([_][]const u8{ "/Users/", "/home/" }) |root| {
        if (!std.mem.startsWith(u8, text, root)) continue;
        var n = root.len;
        while (n < text.len and text[n] != '/' and text[n] != '"' and text[n] != ' ') n += 1;
        return if (n == root.len) null else n;
    }
    return null;
}

const testing = std.testing;

fn keyOf(target: Target, body: []const u8, options: Options) ![]u8 {
    return key(testing.allocator, target, body, options);
}

fn expectSame(a: []const u8, b: []const u8) !void {
    const ka = try keyOf(.{}, a, .{});
    defer testing.allocator.free(ka);
    const kb = try keyOf(.{}, b, .{});
    defer testing.allocator.free(kb);
    try testing.expectEqualStrings(ka, kb);
}

fn expectDiffers(a: []const u8, b: []const u8) !void {
    const ka = try keyOf(.{}, a, .{});
    defer testing.allocator.free(ka);
    const kb = try keyOf(.{}, b, .{});
    defer testing.allocator.free(kb);
    try testing.expect(!std.mem.eql(u8, ka, kb));
}

test "key order does not matter" {
    try expectSame(
        \\{"model":"claude-opus-5","messages":[{"role":"user","content":"hi"}]}
    ,
        \\{"messages":[{"content":"hi","role":"user"}],"model":"claude-opus-5"}
    );
}

test "integer and float zero are one temperature" {
    try expectSame(
        \\{"model":"m","temperature":0,"messages":[]}
    ,
        \\{"model":"m","temperature":0.0,"messages":[]}
    );
}

test "whitespace does not matter" {
    try expectSame(
        \\{"model":"m","messages":[]}
    , "{\n  \"model\": \"m\",\n  \"messages\": []\n}");
}

test "injected date is scrubbed" {
    try expectSame(
        \\{"system":"Today is 2026-08-31T14:22:03Z"}
    ,
        \\{"system":"Today is 2026-09-01T09:03:41Z"}
    );
}

test "injected uuid is scrubbed" {
    try expectSame(
        \\{"c":"session 6f1c2b90-9a4e-4f21-b7d3-1e5a8c0d4e77"}
    ,
        \\{"c":"session 0b7d13aa-51ce-4a02-9c88-77fe2d4b1a90"}
    );
}

test "home directory is scrubbed across machines" {
    try expectSame(
        \\{"c":"read /Users/tunardev/app/src/main.zig"}
    ,
        \\{"c":"read /home/runner/app/src/main.zig"}
    );
}

test "different prompt must not collide" {
    try expectDiffers(
        \\{"messages":[{"role":"user","content":"summarize this"}]}
    ,
        \\{"messages":[{"role":"user","content":"translate this"}]}
    );
}

test "different model must not collide" {
    try expectDiffers(
        \\{"model":"claude-opus-5","messages":[]}
    ,
        \\{"model":"claude-sonnet-5","messages":[]}
    );
}

test "changed tool schema must not collide" {
    try expectDiffers(
        \\{"tools":[{"name":"read","input_schema":{"path":"string"}}]}
    ,
        \\{"tools":[{"name":"read","input_schema":{"path":"string","limit":"int"}}]}
    );
}

test "changed temperature must not collide" {
    try expectDiffers(
        \\{"model":"m","temperature":0,"messages":[]}
    ,
        \\{"model":"m","temperature":0.7,"messages":[]}
    );
}

test "extra conversation turn must not collide" {
    try expectDiffers(
        \\{"messages":[{"role":"user","content":"a"}]}
    ,
        \\{"messages":[{"role":"user","content":"a"},{"role":"assistant","content":"b"}]}
    );
}

test "large integers keep full precision" {
    try expectDiffers(
        \\{"n":9007199254740993}
    ,
        \\{"n":9007199254740992}
    );
}

test "a string value cannot forge structure" {
    try expectDiffers(
        \\{"a":"1","b":"2"}
    ,
        \\{"a":"1\",b:\"2"}
    );
}

test "an object key cannot forge structure" {
    try expectDiffers(
        \\{"x":1,"y":2}
    ,
        \\{"x:1,y":2}
    );
}

test "different files under one home directory stay distinct" {
    try expectDiffers(
        \\{"c":"read /Users/me/src/main.zig"}
    ,
        \\{"c":"read /Users/me/src/build.zig"}
    );
}

test "a path used as an object key does not swallow its value" {
    try expectDiffers(
        \\{"/tmp/a":1}
    ,
        \\{"/tmp/b":999}
    );
}

test "dated model snapshots stay distinct" {
    try expectDiffers(
        \\{"model":"gpt-4o-2024-08-06","messages":[]}
    ,
        \\{"model":"gpt-4o-2024-11-20","messages":[]}
    );
}

test "placeholder text cannot impersonate a scrubbed value" {
    try expectDiffers(
        \\{"c":"/Users/me/x"}
    ,
        \\{"c":"<HOME>/x"}
    );
}

test "a non-json body cannot collide with an encoded one" {
    try expectDiffers(
        \\{"a":"1"}
    , "j o1:k1:a s1:1");
}

test "a large float still encodes rather than falling back" {
    const k = try keyOf(.{}, "{\"n\":1e40}", .{});
    defer testing.allocator.free(k);
    try testing.expect(std.mem.startsWith(u8, k, "m4:POST"));
    try testing.expect(std.mem.indexOf(u8, k, "10000000000000000000000000000000000000000") != null);
}

test "an out of range date is not treated as a timestamp" {
    try expectDiffers(
        \\{"id":"9999-99-99"}
    ,
        \\{"id":"1234-56-78"}
    );
}

test "method provider and path are part of the identity" {
    const a = try keyOf(.{ .method = "POST", .provider = "anthropic", .path = "/v1/messages/AAA/cancel" }, "", .{});
    defer testing.allocator.free(a);
    const b = try keyOf(.{ .method = "POST", .provider = "anthropic", .path = "/v1/messages/BBB/cancel" }, "", .{});
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));

    const get = try keyOf(.{ .method = "GET", .provider = "anthropic", .path = "/v1/models" }, "", .{});
    defer testing.allocator.free(get);
    const post = try keyOf(.{ .method = "POST", .provider = "anthropic", .path = "/v1/models" }, "", .{});
    defer testing.allocator.free(post);
    try testing.expect(!std.mem.eql(u8, get, post));

    const one = try keyOf(.{ .provider = "openai", .path = "/v1/chat/completions" }, "{\"m\":1}", .{});
    defer testing.allocator.free(one);
    const two = try keyOf(.{ .provider = "groq", .path = "/v1/chat/completions" }, "{\"m\":1}", .{});
    defer testing.allocator.free(two);
    try testing.expect(!std.mem.eql(u8, one, two));
}

test "a credential in the query string never reaches the key" {
    const k = try keyOf(.{ .provider = "gemini", .path = "/v1/models/x?key=AIzaSyREALSECRET" }, "", .{});
    defer testing.allocator.free(k);
    try testing.expect(std.mem.indexOf(u8, k, "AIzaSyREALSECRET") == null);
    const without = try keyOf(.{ .provider = "gemini", .path = "/v1/models/x" }, "", .{});
    defer testing.allocator.free(without);
    try testing.expect(!std.mem.eql(u8, k, without));
}

test "query parameter order does not matter" {
    const a = try keyOf(.{ .path = "/v1/x?alpha=1&beta=2" }, "", .{});
    defer testing.allocator.free(a);
    const b = try keyOf(.{ .path = "/v1/x?beta=2&alpha=1" }, "", .{});
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "an ignored field stops affecting the key" {
    const with = [_][]const u8{"metadata.request_id"};
    const a = try keyOf(.{}, "{\"model\":\"m\",\"metadata\":{\"request_id\":\"abc\"}}", .{ .ignore = &with });
    defer testing.allocator.free(a);
    const b = try keyOf(.{}, "{\"model\":\"m\",\"metadata\":{\"request_id\":\"xyz\"}}", .{ .ignore = &with });
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "a nested ignore path does not drop a top level field of the same name" {
    const ignore = [_][]const u8{"a.b"};
    const a = try keyOf(.{}, "{\"b\":\"top\",\"a\":{\"b\":\"nested\"}}", .{ .ignore = &ignore });
    defer testing.allocator.free(a);
    const b = try keyOf(.{}, "{\"b\":\"CHANGED\",\"a\":{\"b\":\"nested\"}}", .{ .ignore = &ignore });
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "scrubbers can be disabled" {
    const a = try keyOf(.{}, "{\"s\":\"2026-08-31T14:22:03Z\"}", .{ .scrubbers = &.{} });
    defer testing.allocator.free(a);
    const b = try keyOf(.{}, "{\"s\":\"2026-09-01T09:03:41Z\"}", .{ .scrubbers = &.{} });
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "a non json body matches itself and nothing else" {
    try expectSame("not json at all", "not json at all");
    try expectDiffers("not json at all", "also not json");
}
