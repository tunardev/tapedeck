//! Forwarding a request to the real provider and capturing what came back.

const std = @import("std");
const Io = std.Io;
const http = std.http;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A request as it arrived from the client, with the provider prefix stripped.
pub const Request = struct {
    method: http.Method,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
};

/// What the provider returned, with the body fully drained. Caller owns it.
pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,

    pub fn deinit(r: Response, gpa: std.mem.Allocator) void {
        for (r.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(r.headers);
        gpa.free(r.body);
    }
};

/// Headers describing the wire encoding of a body we have already decoded, or
/// that only the hop sending the reply can set correctly.
pub fn isHopHeader(name: []const u8) bool {
    const hop = [_][]const u8{
        "content-encoding",
        "content-length",
        "transfer-encoding",
        "connection",
        "host",
    };
    for (hop) |h| {
        if (std.ascii.eqlIgnoreCase(name, h)) return true;
    }
    return false;
}

/// Send `req` to `base` and drain the response.
///
/// A non-2xx status is a recordable outcome, not a failure: a suite that
/// asserts on a 429 must be able to replay one.
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
        // The client's Host and framing headers describe the hop to us, not to
        // the provider; the client sets both correctly for the real destination.
        if (isHopHeader(h.name)) continue;
        try extra.append(gpa, .{ .name = h.name, .value = h.value });
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var r = try client.request(req.method, uri, .{
        .extra_headers = extra.items,
        .keep_alive = false,
    });
    defer r.deinit();

    const body_copy = try gpa.dupe(u8, req.body);
    defer gpa.free(body_copy);
    try r.sendBodyComplete(body_copy);

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
        const n = body_reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try body.appendSlice(gpa, chunk[0..n]);
    }

    return .{
        .status = @intFromEnum(response.head.status),
        .headers = try out_headers.toOwnedSlice(gpa),
        .body = try body.toOwnedSlice(gpa),
    };
}

const testing = std.testing;

test "hop headers are recognised case-insensitively" {
    try testing.expect(isHopHeader("Content-Encoding"));
    try testing.expect(isHopHeader("content-length"));
    try testing.expect(isHopHeader("TRANSFER-ENCODING"));
    try testing.expect(isHopHeader("Host"));
    try testing.expect(!isHopHeader("content-type"));
    try testing.expect(!isHopHeader("anthropic-version"));
}
