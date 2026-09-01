const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const tapedeck = @import("tapedeck");
const upstream = tapedeck.upstream;
const testing = std.testing;

const Behaviour = union(enum) {
    ok: []const u8,
    redirect_to: u16,
    short_body,
    echo_body_len,
};

const Stub = struct {
    server: net.Server,
    port: u16,
    io: Io,
    behaviour: Behaviour,
    running: std.atomic.Value(bool) = .init(true),
    hits: std.atomic.Value(usize) = .init(0),
    saw_credential: std.atomic.Value(bool) = .init(false),
    body_len: std.atomic.Value(usize) = .init(0),

    fn start(io: Io, hint: u16, behaviour: Behaviour) !Stub {
        var port = hint;
        while (port < hint +| 200) : (port += 1) {
            const addr: net.IpAddress = try .parseIp4("127.0.0.1", port);
            const s = addr.listen(io, .{}) catch continue;
            return .{ .server = s, .port = port, .io = io, .behaviour = behaviour };
        }
        return error.NoFreePort;
    }

    fn serve(s: *Stub) void {
        while (s.running.load(.seq_cst)) {
            const stream = s.server.accept(s.io) catch break;
            defer stream.close(s.io);
            if (!s.running.load(.seq_cst)) break;
            s.handle(stream) catch {};
        }
    }

    fn handle(s: *Stub, stream: net.Stream) !void {
        var in_buf: [64 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var writer = stream.writer(s.io, &out_buf);
        var server = http.Server.init(&reader.interface, &writer.interface);
        var req = server.receiveHead() catch return;

        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (upstream.isCredential(h.name)) s.saw_credential.store(true, .seq_cst);
        }

        var drain: [64 * 1024]u8 = undefined;
        const body_reader = req.readerExpectNone(&drain);
        var total: usize = 0;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = body_reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            total += n;
        }
        s.body_len.store(total, .seq_cst);
        _ = s.hits.fetchAdd(1, .seq_cst);

        switch (s.behaviour) {
            .ok => |payload| {
                req.respond(payload, .{ .keep_alive = false }) catch {};
                writer.interface.flush() catch {};
            },
            .redirect_to => |port| {
                var loc: [64]u8 = undefined;
                const target = try std.fmt.bufPrint(&loc, "http://127.0.0.1:{d}/moved", .{port});
                req.respond("", .{
                    .status = @enumFromInt(302),
                    .extra_headers = &.{.{ .name = "location", .value = target }},
                    .keep_alive = false,
                }) catch {};
                writer.interface.flush() catch {};
            },
            .short_body => {
                // Declares far more than it sends, then hangs up: a provider
                // dropping mid-response. http.Server would not let us frame
                // this, so the bytes go out raw.
                var raw = stream.writer(s.io, &out_buf);
                raw.interface.writeAll(
                    "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5000\r\n\r\ntruncated",
                ) catch {};
                raw.interface.flush() catch {};
            },
            .echo_body_len => {
                var payload: [64]u8 = undefined;
                const text = try std.fmt.bufPrint(&payload, "{{\"received\":{d}}}", .{total});
                req.respond(text, .{ .keep_alive = false }) catch {};
                writer.interface.flush() catch {};
            },
        }
    }

    fn stop(s: *Stub) void {
        s.running.store(false, .seq_cst);
        const addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", s.port) catch return;
        const conn = addr.connect(s.io, .{ .mode = .stream }) catch return;
        conn.close(s.io);
    }
};

fn request(gpa: std.mem.Allocator, io: Io, port: u16, body: []const u8) !upstream.Response {
    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(base);
    return upstream.forward(gpa, io, base, .{
        .method = .POST,
        .path = "/v1/messages",
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = "Bearer sk-must-not-travel" },
            .{ .name = "x-api-key", .value = "sk-must-not-travel" },
        },
        .body = body,
    });
}

test "credentials reach the provider but never a redirect target" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var elsewhere = try Stub.start(io, 39310, .{ .ok = "should never be reached" });
    const et = try std.Thread.spawn(.{}, Stub.serve, .{&elsewhere});
    defer et.join();
    defer elsewhere.stop();

    var provider = try Stub.start(io, 39330, .{ .redirect_to = elsewhere.port });
    const pt = try std.Thread.spawn(.{}, Stub.serve, .{&provider});
    defer pt.join();
    defer provider.stop();

    const got = try request(gpa, io, provider.port, "{}");
    defer got.deinit(gpa);

    // The provider must actually receive the key, or nothing authenticates.
    try testing.expect(provider.saw_credential.load(.seq_cst));
    // The 3xx is recorded rather than followed, so no other host is contacted
    // and the key cannot travel with it.
    try testing.expectEqual(@as(u16, 302), got.status);
    try testing.expectEqual(@as(usize, 0), elsewhere.hits.load(.seq_cst));
    try testing.expect(!elsewhere.saw_credential.load(.seq_cst));
}

test "a truncated response body is an error, not a short recording" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var provider = try Stub.start(io, 39350, .short_body);
    const pt = try std.Thread.spawn(.{}, Stub.serve, .{&provider});
    defer pt.join();
    defer provider.stop();

    try testing.expectError(error.UpstreamBodyTruncated, request(gpa, io, provider.port, "{}"));
}

test "a large request body is forwarded whole" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var provider = try Stub.start(io, 39370, .echo_body_len);
    const pt = try std.Thread.spawn(.{}, Stub.serve, .{&provider});
    defer pt.join();
    defer provider.stop();

    // Well past the 16 KB connection buffers, and the size of a real request
    // carrying a system prompt and tool schemas.
    const size = 256 * 1024;
    const body = try gpa.alloc(u8, size);
    defer gpa.free(body);
    @memset(body, 'x');
    body[0] = '{';
    body[size - 1] = '}';

    const got = try request(gpa, io, provider.port, body);
    defer got.deinit(gpa);

    try testing.expectEqual(@as(usize, size), provider.body_len.load(.seq_cst));
    var expect: [64]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&expect, "{{\"received\":{d}}}", .{size}),
        got.body,
    );
}

test "a large response body is captured whole" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const payload = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(payload);
    @memset(payload, 'y');

    var provider = try Stub.start(io, 39390, .{ .ok = payload });
    const pt = try std.Thread.spawn(.{}, Stub.serve, .{&provider});
    defer pt.join();
    defer provider.stop();

    const got = try request(gpa, io, provider.port, "{}");
    defer got.deinit(gpa);
    try testing.expectEqual(payload.len, got.body.len);
    try testing.expectEqualSlices(u8, payload, got.body);
}

test "credential classification covers the providers we front" {
    for ([_][]const u8{
        "authorization",       "Authorization",        "proxy-authorization",
        "x-api-key",           "X-Api-Key",            "api-key",
        "x-goog-api-key",      "x-amz-security-token", "cookie",
        "openai-organization",
    }) |name| {
        try testing.expect(upstream.isCredential(name));
    }
    for ([_][]const u8{ "content-type", "anthropic-version", "accept", "user-agent" }) |name| {
        try testing.expect(!upstream.isCredential(name));
    }
}
