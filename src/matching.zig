//! Match keys for cassette lookup.
//!
//! Two runs of the same test rarely produce byte-identical request bodies, so a
//! byte comparison re-records constantly. Two *different* calls must never
//! collide, because a wrong replay is a green test that proves nothing. This
//! module turns a request body into a key that tolerates the first without
//! permitting the second.

const std = @import("std");

/// Volatile spans replaced before the key is formed.
///
/// Agents inject all three of these into prompts as a matter of course: the
/// current date, a session or tool-call id, and absolute paths that differ
/// between a laptop and a CI runner. Canonical JSON alone does not survive them.
pub const Scrubber = enum {
    timestamp,
    uuid,
    abs_path,

    fn placeholder(s: Scrubber) []const u8 {
        return switch (s) {
            .timestamp => "<TIMESTAMP>",
            .uuid => "<UUID>",
            .abs_path => "<PATH>",
        };
    }

    fn matchLen(s: Scrubber, text: []const u8) ?usize {
        return switch (s) {
            .timestamp => matchIso8601(text),
            .uuid => matchUuid(text),
            .abs_path => matchAbsPath(text),
        };
    }
};

/// The default scrub set.
pub const all_scrubbers = [_]Scrubber{ .timestamp, .uuid, .abs_path };

/// The key a cassette entry is stored and looked up under. Caller owns the result.
///
/// A body that is not JSON falls back to its own bytes, so it still matches
/// itself exactly rather than silently colliding with everything else.
pub fn key(
    gpa: std.mem.Allocator,
    body: []const u8,
    scrubbers: []const Scrubber,
    /// Dotted JSON paths dropped before the key is formed, e.g.
    /// `metadata.request_id`. Field-level and exact, unlike a pattern, which
    /// can silently over-match and collapse two different calls into one.
    ignore: []const []const u8,
) ![]u8 {
    const canonical = canonicalize(gpa, body, ignore) catch try gpa.dupe(u8, body);
    defer gpa.free(canonical);
    return scrub(gpa, canonical, scrubbers);
}

fn canonicalize(gpa: std.mem.Allocator, body: []const u8, ignore: []const []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeCanonical(gpa, parsed.value, &out, "", ignore);
    return out.toOwnedSlice(gpa);
}

/// Whether `prefix` + `name` names an ignored path.
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

/// Order-independent rendering of a JSON value.
///
/// `std.json` preserves document order, so sorting here is what makes the key
/// stable rather than a no-op the parser happens to supply.
fn writeCanonical(
    gpa: std.mem.Allocator,
    v: std.json.Value,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    ignore: []const []const u8,
) !void {
    switch (v) {
        .object => |obj| {
            const keys = try gpa.alloc([]const u8, obj.count());
            defer gpa.free(keys);
            for (obj.keys(), 0..) |k, i| keys[i] = k;
            std.mem.sortUnstable([]const u8, keys, {}, lessThanSlice);

            try out.append(gpa, '{');
            for (keys) |k| {
                if (isIgnored(prefix, k, ignore)) continue;
                const child = if (prefix.len == 0)
                    try gpa.dupe(u8, k)
                else
                    try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, k });
                defer gpa.free(child);
                try out.appendSlice(gpa, k);
                try out.append(gpa, ':');
                try writeCanonical(gpa, obj.get(k).?, out, child, ignore);
                try out.append(gpa, ',');
            }
            try out.append(gpa, '}');
        },
        .array => |items| {
            try out.append(gpa, '[');
            for (items.items) |item| {
                try writeCanonical(gpa, item, out, prefix, ignore);
                try out.append(gpa, ',');
            }
            try out.append(gpa, ']');
        },
        // `0` and `0.0` are the same temperature; SDKs across languages
        // disagree on which one they serialize. Whole floats are written as
        // integers rather than the reverse, which would lose precision above 2^53.
        .integer => |n| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}", .{n}));
        },
        .float => |f| {
            var buf: [40]u8 = undefined;
            if (f == @trunc(f) and @abs(f) < 9007199254740992.0) {
                const as_int: i64 = @intFromFloat(f);
                try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}", .{as_int}));
            } else {
                try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}", .{f}));
            }
        },
        .number_string => |s| try out.appendSlice(gpa, s),
        .string => |s| {
            try out.append(gpa, '"');
            try out.appendSlice(gpa, s);
            try out.append(gpa, '"');
        },
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .null => try out.appendSlice(gpa, "null"),
    }
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Every pattern is ASCII, so byte-wise scanning copies multi-byte UTF-8
/// sequences through untouched.
fn scrub(gpa: std.mem.Allocator, text: []const u8, scrubbers: []const Scrubber) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);

    var i: usize = 0;
    outer: while (i < text.len) {
        for (scrubbers) |s| {
            if (s.matchLen(text[i..])) |n| {
                try out.appendSlice(gpa, s.placeholder());
                i += n;
                continue :outer;
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// `2026-08-31T14:22:03Z`, `2026-08-31 14:22:03.123`, or a bare `2026-08-31`.
fn matchIso8601(t: []const u8) ?usize {
    if (t.len < 10) return null;
    const date = isDigit(t[0]) and isDigit(t[1]) and isDigit(t[2]) and isDigit(t[3]) and
        t[4] == '-' and isDigit(t[5]) and isDigit(t[6]) and
        t[7] == '-' and isDigit(t[8]) and isDigit(t[9]);
    if (!date) return null;
    if (t.len < 19 or (t[10] != 'T' and t[10] != ' ')) return 10;
    const time = isDigit(t[11]) and isDigit(t[12]) and t[13] == ':' and
        isDigit(t[14]) and isDigit(t[15]) and t[16] == ':' and
        isDigit(t[17]) and isDigit(t[18]);
    if (!time) return 10;
    var n: usize = 19;
    while (n < t.len and (t[n] == 'Z' or t[n] == '.' or isDigit(t[n]))) n += 1;
    return n;
}

fn matchUuid(t: []const u8) ?usize {
    const len = 36;
    if (t.len < len) return null;
    for (t[0..len], 0..) |c, i| {
        const ok = switch (i) {
            8, 13, 18, 23 => c == '-',
            else => isHex(c),
        };
        if (!ok) return null;
    }
    return len;
}

fn matchAbsPath(t: []const u8) ?usize {
    const prefixes = [_][]const u8{ "/Users/", "/home/", "/private/tmp/", "/tmp/" };
    for (prefixes) |p| {
        if (t.len >= p.len and std.mem.eql(u8, t[0..p.len], p)) {
            var n = p.len;
            while (n < t.len and t[n] != '"' and t[n] != ' ' and t[n] != ',' and t[n] != '\n') n += 1;
            return n;
        }
    }
    return null;
}

const testing = std.testing;

fn expectSame(a: []const u8, b: []const u8) !void {
    const ka = try key(testing.allocator, a, &all_scrubbers, &.{});
    defer testing.allocator.free(ka);
    const kb = try key(testing.allocator, b, &all_scrubbers, &.{});
    defer testing.allocator.free(kb);
    try testing.expectEqualStrings(ka, kb);
}

fn expectDiffers(a: []const u8, b: []const u8) !void {
    const ka = try key(testing.allocator, a, &all_scrubbers, &.{});
    defer testing.allocator.free(ka);
    const kb = try key(testing.allocator, b, &all_scrubbers, &.{});
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
    ,
        "{\n  \"model\": \"m\",\n  \"messages\": []\n}",
    );
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

test "absolute path is scrubbed across machines" {
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

test "scrubbing keeps surrounding text distinct" {
    try expectDiffers(
        \\{"c":"from 2026-01-01 to 2026-02-01 summarize"}
    ,
        \\{"c":"from 2026-01-01 to 2026-02-01 translate"}
    );
}

test "scrubbers can be disabled" {
    const a = try key(testing.allocator,
        \\{"system":"Today is 2026-08-31T14:22:03Z"}
    , &.{}, &.{});
    defer testing.allocator.free(a);
    const b = try key(testing.allocator,
        \\{"system":"Today is 2026-09-01T09:03:41Z"}
    , &.{}, &.{});
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "non json body matches itself and nothing else" {
    try expectSame("not json at all", "not json at all");
    try expectDiffers("not json at all", "also not json");
}

test "large integers keep full precision" {
    try expectDiffers(
        \\{"n":9007199254740993}
    ,
        \\{"n":9007199254740992}
    );
}

fn keyIgnoring(body: []const u8, ignore: []const []const u8) ![]u8 {
    return key(testing.allocator, body, &all_scrubbers, ignore);
}

test "an ignored field stops affecting the key" {
    const a =
        \\{"model":"m","metadata":{"request_id":"abc"}}
    ;
    const b =
        \\{"model":"m","metadata":{"request_id":"xyz"}}
    ;
    const with = [_][]const u8{"metadata.request_id"};

    const ka = try keyIgnoring(a, &with);
    defer testing.allocator.free(ka);
    const kb = try keyIgnoring(b, &with);
    defer testing.allocator.free(kb);
    try testing.expectEqualStrings(ka, kb);

    const na = try keyIgnoring(a, &.{});
    defer testing.allocator.free(na);
    const nb = try keyIgnoring(b, &.{});
    defer testing.allocator.free(nb);
    try testing.expect(!std.mem.eql(u8, na, nb));
}

test "a nested ignore path does not drop a top level field of the same name" {
    const a =
        \\{"b":"top","a":{"b":"nested"}}
    ;
    const b =
        \\{"b":"CHANGED","a":{"b":"nested"}}
    ;
    const ignore = [_][]const u8{"a.b"};
    const ka = try keyIgnoring(a, &ignore);
    defer testing.allocator.free(ka);
    const kb = try keyIgnoring(b, &ignore);
    defer testing.allocator.free(kb);
    // Only `a.b` is ignored, so the top-level `b` must still separate these.
    try testing.expect(!std.mem.eql(u8, ka, kb));
}

test "ignoring a path that does not exist is harmless" {
    const body =
        \\{"model":"m"}
    ;
    const ignore = [_][]const u8{"nope.not.here"};
    const k1 = try keyIgnoring(body, &ignore);
    defer testing.allocator.free(k1);
    const k2 = try keyIgnoring(body, &.{});
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings(k1, k2);
}
