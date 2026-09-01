const std = @import("std");
const Io = std.Io;
const http = std.http;

const timeline_mod = @import("timeline.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: http.Method,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    chunked: bool,
    timeline: []timeline_mod.Chunk,

    pub fn deinit(r: Response, gpa: std.mem.Allocator) void {
        for (r.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(r.headers);
        gpa.free(r.body);
        gpa.free(r.timeline);
    }
};

pub fn isHopHeader(name: []const u8) bool {
    const hop = [_][]const u8{
        "content-encoding",
        "content-length",
        "transfer-encoding",
        "connection",
        "host",
        "accept-encoding",
        "user-agent",
        "date",
    };
    for (hop) |h| {
        if (std.ascii.eqlIgnoreCase(name, h)) return true;
    }
    return false;
}

pub fn isCredential(name: []const u8) bool {
    const names = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "x-amz-security-token",
        "cookie",
        "openai-organization",
        "openai-project",
    };
    for (names) |h| {
        if (std.ascii.eqlIgnoreCase(name, h)) return true;
    }
    return false;
}

fn hasControlBytes(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

pub fn forward(
    gpa: std.mem.Allocator,
    io: Io,
    base: []const u8,
    req: Request,
) !Response {
    const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{
        std.mem.trimEnd(u8, base, "/"),
        req.path,
    });
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    var extra: std.ArrayList(http.Header) = .empty;
    defer extra.deinit(gpa);
    for (req.headers) |h| {
        if (isHopHeader(h.name)) continue;
        if (hasControlBytes(h.name) or hasControlBytes(h.value)) continue;
        try extra.append(gpa, .{ .name = h.name, .value = h.value });
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var r = try client.request(req.method, uri, .{
        .extra_headers = extra.items,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer r.deinit();

    if (req.method.requestHasBody()) {
        const body_copy = try gpa.dupe(u8, req.body);
        defer gpa.free(body_copy);
        try r.sendBodyComplete(body_copy);
    } else {
        try r.sendBodiless();
    }

    var redirect_buffer: [8192]u8 = undefined;
    var response = try r.receiveHead(&redirect_buffer);

    var out_headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (out_headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        out_headers.deinit(gpa);
    }
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (isHopHeader(h.name)) continue;
        try out_headers.append(gpa, .{
            .name = try gpa.dupe(u8, h.name),
            .value = try gpa.dupe(u8, h.value),
        });
    }

    var transfer_buffer: [8192]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const body_reader = response.readerDecompressing(
        &transfer_buffer,
        &decompress,
        &decompress_buffer,
    );

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    var marks: std.ArrayList(timeline_mod.Chunk) = .empty;
    errdefer marks.deinit(gpa);

    var chunk: [4096]u8 = undefined;
    var last = Io.Timestamp.now(io, .awake);
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch return error.UpstreamBodyTruncated;
        if (n == 0) break;
        const now = Io.Timestamp.now(io, .awake);
        if (marks.items.len < timeline_mod.max_chunks) {
            const ms = @divTrunc(now.nanoseconds - last.nanoseconds, std.time.ns_per_ms);
            try marks.append(gpa, .{
                .delay_ms = @intCast(std.math.clamp(ms, 0, timeline_mod.max_delay_ms)),
                .len = @intCast(n),
            });
        }
        last = now;
        try body.appendSlice(gpa, chunk[0..n]);
    }
    if (marks.items.len >= timeline_mod.max_chunks) marks.clearRetainingCapacity();
    if (response.head.content_length) |declared| {
        if (body.items.len != declared) return error.UpstreamBodyTruncated;
    }

    return .{
        .status = @intFromEnum(response.head.status),
        .headers = try out_headers.toOwnedSlice(gpa),
        .body = try body.toOwnedSlice(gpa),
        .chunked = response.head.transfer_encoding == .chunked,
        .timeline = try marks.toOwnedSlice(gpa),
    };
}

const testing = std.testing;

test "hop headers are recognised case-insensitively" {
    try testing.expect(isHopHeader("Content-Encoding"));
    try testing.expect(isHopHeader("content-length"));
    try testing.expect(isHopHeader("TRANSFER-ENCODING"));
    try testing.expect(isHopHeader("Host"));
    try testing.expect(isHopHeader("Date"));
    try testing.expect(!isHopHeader("content-type"));
    try testing.expect(!isHopHeader("anthropic-version"));
}
