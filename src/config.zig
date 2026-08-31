//! Optional `config.json` in the tapedeck home directory.
//!
//! JSON rather than TOML because `std.json` exists and a TOML parser would be
//! this project's first dependency, for a file most users never open.

const std = @import("std");
const Io = std.Io;

pub const Provider = struct {
    /// First path segment that selects this provider.
    name: []const u8,
    /// Real API root.
    base: []const u8,
    /// Environment variable the provider's SDK reads. Not derived from `name`
    /// because vendors do not agree on the pattern.
    env: []const u8,
};

pub const defaults = [_]Provider{
    .{ .name = "anthropic", .base = "https://api.anthropic.com", .env = "ANTHROPIC_BASE_URL" },
    .{ .name = "openai", .base = "https://api.openai.com", .env = "OPENAI_BASE_URL" },
    .{ .name = "gemini", .base = "https://generativelanguage.googleapis.com", .env = "GOOGLE_GEMINI_BASE_URL" },
};

/// Dollars per million tokens.
pub const Price = struct {
    model: []const u8,
    input: f64,
    output: f64,
};

pub const Config = struct {
    /// Heap-allocated: an `ArenaAllocator` handed out by value loses the
    /// pointer its own `allocator()` captured, and the arena leaks.
    arena: *std.heap.ArenaAllocator,
    providers: []const Provider,
    /// Dotted JSON paths dropped from the match key.
    ignore: []const []const u8,
    /// Per-model prices. Absent by default: a shipped price table goes stale
    /// silently, and a confidently wrong dollar figure is worse than none.
    pricing: []const Price,
    /// Store a hash of the request instead of the request itself. Matching is
    /// unaffected; readable diffs are the cost. Off by default because a
    /// reviewable cassette is usually worth more than an opaque one.
    hash_keys: bool = false,

    /// Dollars for these tokens, or null when the model has no configured price.
    ///
    /// Longest-prefix, because providers report dated snapshot ids: a user who
    /// prices `claude-opus-4` means that to cover `claude-opus-4-20250514`.
    pub fn cost(c: Config, model: []const u8, input: u64, output: u64) ?f64 {
        var best: ?Price = null;
        for (c.pricing) |p| {
            if (!std.mem.startsWith(u8, model, p.model)) continue;
            if (best == null or p.model.len > best.?.model.len) best = p;
        }
        const p = best orelse return null;
        const mi: f64 = @floatFromInt(input);
        const mo: f64 = @floatFromInt(output);
        return (mi / 1_000_000.0) * p.input + (mo / 1_000_000.0) * p.output;
    }

    pub fn deinit(c: *Config) void {
        const gpa = c.arena.child_allocator;
        c.arena.deinit();
        gpa.destroy(c.arena);
    }

    /// Load `<dir>/config.json`. A missing file yields the defaults; a
    /// malformed one is an error, because silently falling back to defaults
    /// would hide a typo that changes which calls match.
    pub fn load(gpa: std.mem.Allocator, io: Io, dir: []const u8) !Config {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const path = try std.fs.path.join(a, &.{ dir, "config.json" });
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return .{
                .arena = arena,
                .providers = try a.dupe(Provider, &defaults),
                .ignore = &.{},
                .pricing = &.{},
            },
            else => return e,
        };

        const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch {
            return error.MalformedConfig;
        };
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.MalformedConfig,
        };

        // A misspelled key would otherwise be silently ignored, which is
        // exactly the typo this file promises to catch.
        const known = [_][]const u8{ "providers", "ignore", "pricing", "hash_keys" };
        for (root.keys()) |name| {
            var ok = false;
            for (known) |k| ok = ok or std.mem.eql(u8, name, k);
            if (!ok) return error.MalformedConfig;
        }

        const hash_keys = if (root.get("hash_keys")) |v| switch (v) {
            .bool => |b| b,
            else => return error.MalformedConfig,
        } else false;

        var providers: std.ArrayList(Provider) = .empty;
        if (root.get("providers")) |v| {
            const items = switch (v) {
                .array => |arr| arr,
                else => return error.MalformedConfig,
            };
            for (items.items) |item| {
                const o = switch (item) {
                    .object => |o| o,
                    else => return error.MalformedConfig,
                };
                const name = stringField(o, "name") orelse return error.MalformedConfig;
                const base = stringField(o, "base") orelse return error.MalformedConfig;
                const env = stringField(o, "env") orelse return error.MalformedConfig;
                try providers.append(a, .{
                    .name = try a.dupe(u8, name),
                    .base = try a.dupe(u8, base),
                    .env = try a.dupe(u8, env),
                });
            }
        }

        var pricing: std.ArrayList(Price) = .empty;
        if (root.get("pricing")) |v| {
            const o = switch (v) {
                .object => |o| o,
                else => return error.MalformedConfig,
            };
            var it = o.iterator();
            while (it.next()) |kv| {
                const spec = switch (kv.value_ptr.*) {
                    .object => |so| so,
                    else => return error.MalformedConfig,
                };
                try pricing.append(a, .{
                    .model = try a.dupe(u8, kv.key_ptr.*),
                    .input = floatField(spec, "input") orelse return error.MalformedConfig,
                    .output = floatField(spec, "output") orelse return error.MalformedConfig,
                });
            }
        }

        var ignore: std.ArrayList([]const u8) = .empty;
        if (root.get("ignore")) |v| {
            const items = switch (v) {
                .array => |arr| arr,
                else => return error.MalformedConfig,
            };
            for (items.items) |item| {
                const s = switch (item) {
                    .string => |s| s,
                    else => return error.MalformedConfig,
                };
                try ignore.append(a, try a.dupe(u8, s));
            }
        }

        return .{
            .arena = arena,
            // A declared provider list replaces the defaults, so a user can
            // front only what they actually call.
            // An explicitly empty list is a statement, and different from
            // omitting the key.
            .providers = if (root.get("providers") != null)
                try providers.toOwnedSlice(a)
            else
                try a.dupe(Provider, &defaults),
            .ignore = try ignore.toOwnedSlice(a),
            .pricing = try pricing.toOwnedSlice(a),
            .hash_keys = hash_keys,
        };
    }
};

fn floatField(o: std.json.ObjectMap, name: []const u8) ?f64 {
    const v = o.get(name) orelse return null;
    const f: f64 = switch (v) {
        .float => |x| x,
        .integer => |n| @floatFromInt(n),
        // An overflowing or non-finite literal arrives as a string.
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    // A negative or non-finite price would print a confident nonsense total.
    if (!std.math.isFinite(f) or f < 0) return null;
    return f;
}

fn stringField(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

fn writeConfig(io: Io, dir: []const u8, body: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{dir});
    defer testing.allocator.free(path);
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "a missing config yields the defaults" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    var c = try Config.load(testing.allocator, t.io(), ".tapedeck-cfg-missing");
    defer c.deinit();
    try testing.expectEqual(defaults.len, c.providers.len);
    try testing.expectEqualStrings("anthropic", c.providers[0].name);
    try testing.expectEqual(@as(usize, 0), c.ignore.len);
}

test "a declared provider list replaces the defaults" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-custom";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"providers":[{"name":"local","base":"http://127.0.0.1:11434","env":"OPENAI_BASE_URL"}]}
    );

    var c = try Config.load(testing.allocator, io, dir);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.providers.len);
    try testing.expectEqualStrings("local", c.providers[0].name);
    try testing.expectEqualStrings("OPENAI_BASE_URL", c.providers[0].env);
}

test "ignore paths are read" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-ignore";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"ignore":["metadata.request_id","trace_id"]}
    );

    var c = try Config.load(testing.allocator, io, dir);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.ignore.len);
    try testing.expectEqualStrings("metadata.request_id", c.ignore[0]);
    // No providers declared, so the defaults still apply.
    try testing.expectEqual(defaults.len, c.providers.len);
}

test "malformed config is an error rather than a silent default" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-bad";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir, "{not json");
    try testing.expectError(error.MalformedConfig, Config.load(testing.allocator, io, dir));
}

test "a provider missing a field is an error" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-partial";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"providers":[{"name":"local","base":"http://x"}]}
    );
    try testing.expectError(error.MalformedConfig, Config.load(testing.allocator, io, dir));
}

test "pricing is read and applied per model" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-price";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"pricing":{"claude-opus-5":{"input":15.0,"output":75.0}}}
    );

    var c = try Config.load(testing.allocator, io, dir);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.pricing.len);

    // 1M input at $15 plus 1M output at $75.
    const total = c.cost("claude-opus-5", 1_000_000, 1_000_000).?;
    try testing.expectApproxEqAbs(@as(f64, 90.0), total, 0.0001);

    // An unpriced model reports no cost rather than a wrong one.
    try testing.expect(c.cost("some-other-model", 1000, 1000) == null);
}

test "an unknown top level key is rejected rather than ignored" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-typo";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    // A silently ignored `ignores` would change which calls match.
    try writeConfig(io, dir,
        \\{"ignores":["metadata.request_id"]}
    );
    try testing.expectError(error.MalformedConfig, Config.load(testing.allocator, io, dir));
}

test "an explicitly empty provider list is honoured" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-empty";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"providers":[]}
    );
    var c = try Config.load(testing.allocator, io, dir);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.providers.len);
}

test "pricing matches the longest configured prefix" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-prefix";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"pricing":{"claude-opus-4":{"input":15,"output":75},
        \\            "claude-opus-4-1":{"input":30,"output":150}}}
    );
    var c = try Config.load(testing.allocator, io, dir);
    defer c.deinit();

    // Providers report dated snapshot ids; an exact match would price nothing.
    try testing.expectApproxEqAbs(@as(f64, 15.0), c.cost("claude-opus-4-20250514", 1_000_000, 0).?, 0.0001);
    // The more specific entry wins where both apply.
    try testing.expectApproxEqAbs(@as(f64, 30.0), c.cost("claude-opus-4-1-20260101", 1_000_000, 0).?, 0.0001);
    try testing.expect(c.cost("gpt-5", 1000, 1000) == null);
}

test "a negative price is rejected" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-negative";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try writeConfig(io, dir,
        \\{"pricing":{"m":{"input":-15,"output":75}}}
    );
    try testing.expectError(error.MalformedConfig, Config.load(testing.allocator, io, dir));
}

test "hash_keys defaults off and is read when present" {
    var t: Io.Threaded = .init(testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    const dir = ".tapedeck-cfg-hash";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var off = try Config.load(testing.allocator, io, ".tapedeck-cfg-nothing");
    defer off.deinit();
    try testing.expectEqual(false, off.hash_keys);

    try writeConfig(io, dir,
        \\{"hash_keys":true}
    );
    var on = try Config.load(testing.allocator, io, dir);
    defer on.deinit();
    try testing.expectEqual(true, on.hash_keys);
}
