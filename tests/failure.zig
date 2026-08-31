//! Failure injection: every way tapedeck can break needs a defined outcome.
//!
//! This sits between a test suite and a paid API, so "crashes" and "silently
//! records nothing" are both unacceptable answers.

const std = @import("std");
const Io = std.Io;
const tapedeck = @import("tapedeck");

const Cassette = tapedeck.cassette.Cassette;
const matching = tapedeck.matching;
const testing = std.testing;

fn writeFile(io: Io, path: []const u8, body: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "a truncated cassette is a clear error, not a silent empty one" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-fail-trunc";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/default.jsonl";

    // A run killed mid-write could leave half a line.
    try writeFile(io, path,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","bo
    );

    // Loading must fail loudly. Returning an empty cassette would turn a
    // corrupt file into a silent re-record of everything.
    try testing.expectError(error.CorruptCassette, Cassette.load(testing.allocator, io, path));
}

test "a cassette with an unknown field still loads" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-fail-unknown";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/default.jsonl";

    // A cassette written by a newer tapedeck must not break an older one.
    try writeFile(io, path,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","body":"hi","future_field":42}
    );

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.count());
    const body = try c.get("k").?.body.toBytes(testing.allocator);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hi", body);
}

test "a cassette missing the newer fields loads with defaults" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-fail-old";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/default.jsonl";

    // Exactly the shape M1 wrote, before chunked and usage existed.
    try writeFile(io, path,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","body":"hi"}
    );

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    const e = c.get("k").?;
    try testing.expectEqual(false, e.chunked);
    try testing.expectEqual(@as(u64, 0), e.input_tokens);
    try testing.expectEqualStrings("", e.model);
}

test "a non-json request body still matches itself and nothing else" {
    const gpa = testing.allocator;
    const a = try matching.key(gpa, .{}, "this is not json", .{});
    defer gpa.free(a);
    const b = try matching.key(gpa, .{}, "this is not json", .{});
    defer gpa.free(b);
    const c = try matching.key(gpa, .{}, "this is also not json", .{});
    defer gpa.free(c);

    try testing.expectEqualStrings(a, b);
    try testing.expect(!std.mem.eql(u8, a, c));
}

test "an empty request body is matchable" {
    const gpa = testing.allocator;
    const a = try matching.key(gpa, .{}, "", .{});
    defer gpa.free(a);
    const b = try matching.key(gpa, .{}, "", .{});
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "a cassette directory that cannot be created surfaces an error" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-fail-perm";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    // A regular file where the cassette directory should be.
    try writeFile(io, dir ++ "/blocker", "x");

    // A path whose parent is a regular file must report, not panic.
    try testing.expect(std.meta.isError(
        Cassette.load(testing.allocator, io, dir ++ "/blocker/nested/default.jsonl"),
    ));
}

// Valid JSON of the wrong shape used to panic rather than return an error,
// and catch cannot intercept a panic.
test "wrong-shaped cassette lines are errors, not panics" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const cases = [_][]const u8{
        "[1,2,3]",
        "\"just a string\"",
        "123",
        \\{"key":"k"}
        ,
        \\{"key":123,"status":200,"headers":[],"encoding":"text","body":"x"}
        ,
        \\{"key":"k","status":70000,"headers":[],"encoding":"text","body":"x"}
        ,
        \\{"key":"k","status":200,"headers":{},"encoding":"text","body":"x"}
        ,
        \\{"key":"k","status":200,"headers":[{"name":"n"}],"encoding":"text","body":"x"}
        ,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","body":null}
        ,
        \\{"key":"k","status":200,"headers":[],"encoding":"utf8","body":"x"}
        ,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","body":"x","chunked":"yes"}
        ,
        \\{"key":"k","status":200,"headers":[],"encoding":"text","body":"x","input_tokens":-5}
        ,
        \\{"key":"k","status":200,"headers":[],"encoding":"base64","body":"!!!!"}
        ,
    };

    for (cases, 0..) |line, i| {
        var buf: [64]u8 = undefined;
        const dir = try std.fmt.bufPrint(&buf, ".tapedeck-fail-shape-{d}", .{i});
        defer Io.Dir.cwd().deleteTree(io, dir) catch {};
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/c.jsonl", .{dir});
        defer testing.allocator.free(path);
        try writeFile(io, path, line);
        testing.expectError(error.CorruptCassette, Cassette.load(testing.allocator, io, path)) catch |e| {
            std.debug.print("\n  case {d} did not error: {s}\n", .{ i, line });
            return e;
        };
    }
}

test "a binary request body produces a cassette that reloads" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const dir = ".tapedeck-fail-binary";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/c.jsonl";

    // The key derived from a non-JSON body once carried raw bytes straight
    // into the line, producing a file std.json could never parse again.
    const entry_key = try matching.key(gpa, .{}, &[_]u8{ 0xFF, 0xFE, 0x00 }, .{});
    defer gpa.free(entry_key);

    var c = try Cassette.load(gpa, io, path);
    defer c.deinit();
    try c.insert(.{
        .key = try gpa.dupe(u8, entry_key),
        .status = 200,
        .headers = try gpa.alloc(tapedeck.cassette.Header, 0),
        .body = try tapedeck.cassette.Body.fromBytes(gpa, "hi"),
        .model = try gpa.dupe(u8, ""),
    });
    try c.save(io);

    var reloaded = try Cassette.load(gpa, io, path);
    defer reloaded.deinit();
    try testing.expect(reloaded.get(entry_key) != null);
}

test "a large token count does not break saving" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const dir = ".tapedeck-fail-tokens";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/c.jsonl";

    var c = try Cassette.load(gpa, io, path);
    defer c.deinit();
    try c.insert(.{
        .key = try gpa.dupe(u8, "k"),
        .status = 200,
        .headers = try gpa.alloc(tapedeck.cassette.Header, 0),
        .body = try tapedeck.cassette.Body.fromBytes(gpa, "hi"),
        .model = try gpa.dupe(u8, "m"),
        // An 8-byte format buffer failed above 99,999,999 and discarded the
        // whole run's recordings.
        .input_tokens = 4_000_000_000,
        .output_tokens = 4_000_000_000,
    });
    try c.save(io);

    var reloaded = try Cassette.load(gpa, io, path);
    defer reloaded.deinit();
    try testing.expectEqual(@as(u64, 4_000_000_000), reloaded.get("k").?.input_tokens);
}

test "a duplicate key in a cassette does not leak" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-fail-dup";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/c.jsonl";

    // What a badly resolved merge conflict on a committed cassette looks like.
    try writeFile(io, path,
        \\{"key":"k","status":200,"headers":[{"name":"a","value":"b"}],"encoding":"text","body":"one"}
        \\{"key":"k","status":200,"headers":[{"name":"a","value":"b"}],"encoding":"text","body":"two"}
    );

    var c = try Cassette.load(testing.allocator, io, path);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "header values with awkward bytes round trip" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const dir = ".tapedeck-fail-hdr";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/c.jsonl";

    const headers = try gpa.alloc(tapedeck.cassette.Header, 1);
    headers[0] = .{
        .name = try gpa.dupe(u8, "x-note"),
        .value = try gpa.dupe(u8, "quote\" back\\slash \n newline \tand tab"),
    };

    var c = try Cassette.load(gpa, io, path);
    defer c.deinit();
    try c.insert(.{
        .key = try gpa.dupe(u8, "k"),
        .status = 200,
        .headers = headers,
        .body = try tapedeck.cassette.Body.fromBytes(gpa, "b"),
        .model = try gpa.dupe(u8, ""),
    });
    try c.save(io);

    var reloaded = try Cassette.load(gpa, io, path);
    defer reloaded.deinit();
    try testing.expectEqualStrings(
        "quote\" back\\slash \n newline \tand tab",
        reloaded.get("k").?.headers[0].value,
    );
}
