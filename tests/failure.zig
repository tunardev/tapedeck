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
    const a = try matching.key(gpa, "this is not json", &matching.all_scrubbers, &.{});
    defer gpa.free(a);
    const b = try matching.key(gpa, "this is not json", &matching.all_scrubbers, &.{});
    defer gpa.free(b);
    const c = try matching.key(gpa, "this is also not json", &matching.all_scrubbers, &.{});
    defer gpa.free(c);

    try testing.expectEqualStrings(a, b);
    try testing.expect(!std.mem.eql(u8, a, c));
}

test "an empty request body is matchable" {
    const gpa = testing.allocator;
    const a = try matching.key(gpa, "", &matching.all_scrubbers, &.{});
    defer gpa.free(a);
    const b = try matching.key(gpa, "", &matching.all_scrubbers, &.{});
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
