const std = @import("std");
const Io = std.Io;
const http = std.http;

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

    pub fn deinit(r: Response, gpa: std.mem.Allocator) void {
        for (r.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(r.headers);
        gpa.free(r.body);
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

fn isCredential(name: []const u8) bool {
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
    var privileged: std.ArrayList(http.Header) = .empty;
    defer privileged.deinit(gpa);
    for (req.headers) |h| {
        if (isHopHeader(h.name)) continue;
        if (isCredential(h.name)) {
            try privileged.append(gpa, .{ .name = h.name, .value = h.value });
        } else {
            try extra.append(gpa, .{ .name = h.name, .value = h.value });
        }
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var r = try client.request(req.method, uri, .{
        .extra_headers = extra.items,
        .privileged_headers = privileged.items,
        .redirect_behavior = .not_allowed,
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
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch return error.UpstreamBodyTruncated;
        if (n == 0) break;
        try body.appendSlice(gpa, chunk[0..n]);
    }
    if (response.head.content_length) |declared| {
        if (body.items.len != declared) return error.UpstreamBodyTruncated;
    }

    return .{
        .status = @intFromEnum(response.head.status),
        .headers = try out_headers.toOwnedSlice(gpa),
        .body = try body.toOwnedSlice(gpa),
        .chunked = response.head.transfer_encoding == .chunked,
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
