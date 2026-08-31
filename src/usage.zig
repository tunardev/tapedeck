const std = @import("std");

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    model: []const u8 = "",

    pub fn isEmpty(u: Usage) bool {
        return u.input == 0 and u.output == 0;
    }
};

pub fn parse(gpa: std.mem.Allocator, body: []const u8) Usage {
    if (std.mem.indexOf(u8, body, "data:") != null and
        std.mem.indexOf(u8, body, "\n") != null)
    {
        if (parseStream(gpa, body)) |u| {
            if (!u.isEmpty()) return u;
        }
    }
    return parseObject(gpa, body) orelse .{};
}

fn parseStream(gpa: std.mem.Allocator, body: []const u8) ?Usage {
    var out: Usage = .{};
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0 or payload[0] != '{') continue;
        const u = parseObject(gpa, payload) orelse continue;
        if (u.input > 0) out.input = u.input;
        if (u.output > 0) out.output = u.output;
        if (u.model.len > 0) out.model = u.model;
    }
    return out;
}

fn parseObject(gpa: std.mem.Allocator, text: []const u8) ?Usage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    var out: Usage = .{};
    if (stringAt(root, "model")) |m| out.model = m;
    if (root.get("message")) |m| switch (m) {
        .object => |o| {
            if (stringAt(o, "model")) |name| out.model = name;
            if (o.get("usage")) |u| readUsage(u, &out);
        },
        else => {},
    };
    if (root.get("usage")) |u| readUsage(u, &out);
    if (root.get("usageMetadata")) |u| readUsage(u, &out);

    if (out.model.len > 0) {
        const start = std.mem.indexOf(u8, text, out.model) orelse {
            out.model = "";
            return out;
        };
        out.model = text[start..][0..out.model.len];
    }
    return out;
}

fn readUsage(v: std.json.Value, out: *Usage) void {
    const o = switch (v) {
        .object => |o| o,
        else => return,
    };
    const inputs = [_][]const u8{ "input_tokens", "prompt_tokens", "promptTokenCount" };
    const outputs = [_][]const u8{ "output_tokens", "completion_tokens", "candidatesTokenCount" };
    for (inputs) |k| {
        if (intAt(o, k)) |n| out.input = n;
    }
    for (outputs) |k| {
        if (intAt(o, k)) |n| out.output = n;
    }
}

fn intAt(o: std.json.ObjectMap, name: []const u8) ?u64 {
    const v = o.get(name) orelse return null;
    return switch (v) {
        .integer => |n| if (n < 0) null else @intCast(n),
        else => null,
    };
}

fn stringAt(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "anthropic non-streaming usage" {
    const u = parse(testing.allocator,
        \\{"model":"claude-opus-5","usage":{"input_tokens":120,"output_tokens":45}}
    );
    try testing.expectEqual(@as(u64, 120), u.input);
    try testing.expectEqual(@as(u64, 45), u.output);
    try testing.expectEqualStrings("claude-opus-5", u.model);
}

test "openai usage" {
    const u = parse(testing.allocator,
        \\{"model":"gpt-5","usage":{"prompt_tokens":10,"completion_tokens":7,"total_tokens":17}}
    );
    try testing.expectEqual(@as(u64, 10), u.input);
    try testing.expectEqual(@as(u64, 7), u.output);
    try testing.expectEqualStrings("gpt-5", u.model);
}

test "gemini usage" {
    const u = parse(testing.allocator,
        \\{"usageMetadata":{"promptTokenCount":31,"candidatesTokenCount":9}}
    );
    try testing.expectEqual(@as(u64, 31), u.input);
    try testing.expectEqual(@as(u64, 9), u.output);
}

test "anthropic streamed usage accumulates across events" {
    const sse =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":200,\"output_tokens\":1}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\"}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":88}}\n\n";
    const u = parse(testing.allocator, sse);
    try testing.expectEqual(@as(u64, 200), u.input);
    try testing.expectEqual(@as(u64, 88), u.output);
    try testing.expectEqualStrings("claude-opus-5", u.model);
}

test "a body with no usage reports zeroes" {
    const u = parse(testing.allocator,
        \\{"type":"error","error":{"message":"nope"}}
    );
    try testing.expect(u.isEmpty());
}

test "an unparseable body reports zeroes rather than failing" {
    const u = parse(testing.allocator, "not json at all");
    try testing.expect(u.isEmpty());
    const v = parse(testing.allocator, "data: {broken\n\n");
    try testing.expect(v.isEmpty());
}
