//! Where cassettes live.

const std = @import("std");

/// Cassettes are committed to the repository under test, so the default is
/// project-relative rather than under the user's home. `TAPEDECK_HOME`
/// overrides it, which is also how tests get an isolated directory.
pub const Paths = struct {
    root: []const u8,

    pub fn resolve(gpa: std.mem.Allocator, env: *std.process.Environ.Map) !Paths {
        if (env.get("TAPEDECK_HOME")) |home| {
            return .{ .root = try gpa.dupe(u8, home) };
        }
        return .{ .root = try gpa.dupe(u8, ".tapedeck") };
    }

    pub fn deinit(p: Paths, gpa: std.mem.Allocator) void {
        gpa.free(p.root);
    }

    /// Caller owns the result.
    pub fn cassetteFile(p: Paths, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ p.root, "cassettes", name });
    }
};

/// A cassette name must be one safe path segment.
///
/// The name reaches this from a flag or an environment variable, so `../..`
/// would otherwise let a caller write outside the cassette directory.
pub fn sanitizeName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    for (name) |c| {
        if (c == '/' or c == '\\' or c < 0x20) return null;
    }
    return name;
}

const testing = std.testing;

test "ordinary cassette names are accepted" {
    try testing.expect(sanitizeName("default") != null);
    try testing.expect(sanitizeName("api-tests") != null);
    try testing.expect(sanitizeName("suite_2") != null);
}

test "traversal and separators are rejected" {
    try testing.expect(sanitizeName("../escape") == null);
    try testing.expect(sanitizeName("..") == null);
    try testing.expect(sanitizeName(".") == null);
    try testing.expect(sanitizeName("a/b") == null);
    try testing.expect(sanitizeName("a\\b") == null);
    try testing.expect(sanitizeName("") == null);
    try testing.expect(sanitizeName("bad\nname") == null);
}

test "cassette files live under the root" {
    const p: Paths = .{ .root = "/somewhere/.tapedeck" };
    const f = try p.cassetteFile(testing.allocator, "default.jsonl");
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("/somewhere/.tapedeck/cassettes/default.jsonl", f);
}
