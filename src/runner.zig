const std = @import("std");
const Io = std.Io;

pub fn run(
    io: Io,
    argv: []const []const u8,
    env: *std.process.Environ.Map,
    extra: []const [2][]const u8,
) !u8 {
    if (argv.len == 0) return error.NoCommand;
    for (extra) |pair| try env.put(pair[0], pair[1]);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
    });
    const term = try child.wait(io);

    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        .stopped, .unknown => 1,
    };
}

const testing = std.testing;

fn runShell(io: Io, script: []const u8, extra: []const [2][]const u8) !u8 {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    return run(io, &.{ "sh", "-c", script }, &env, extra);
}

test "exit code is propagated so ci still fails" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    try testing.expectEqual(@as(u8, 3), try runShell(t.io(), "exit 3", &.{}));
}

test "success is zero" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), try runShell(t.io(), "true", &.{}));
}

test "injected env reaches the child" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const extra = [_][2][]const u8{
        .{ "ANTHROPIC_BASE_URL", "http://127.0.0.1:9/anthropic" },
    };
    const code = try runShell(
        t.io(),
        "test \"$ANTHROPIC_BASE_URL\" = http://127.0.0.1:9/anthropic",
        &extra,
    );
    try testing.expectEqual(@as(u8, 0), code);
}

test "signal death is reported as a nonzero code" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    try testing.expect(try runShell(t.io(), "kill -TERM $$", &.{}) != 0);
}

test "empty command is an error" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.NoCommand, run(t.io(), &.{}, &env, &.{}));
}
