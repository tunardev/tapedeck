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

const testing = std.testing;

test "cassette files live under the root" {
    const p: Paths = .{ .root = "/somewhere/.tapedeck" };
    const f = try p.cassetteFile(testing.allocator, "default.jsonl");
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("/somewhere/.tapedeck/cassettes/default.jsonl", f);
}
