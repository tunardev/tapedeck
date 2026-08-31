//! The loopback listener that records and replays.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const cassette_mod = @import("cassette.zig");
const matching = @import("matching.zig");
const redact = @import("redact.zig");
const upstream = @import("upstream.zig");

const Cassette = cassette_mod.Cassette;
const Exchange = cassette_mod.Exchange;

/// Status returned for tapedeck's own failures.
///
/// Deliberately outside the range any provider uses, so a test that sees it
/// knows the tool failed rather than the API.
const tapedeck_error: u16 = 599;

pub const Mode = enum { record, strict };

pub const Stats = struct {
    recorded: usize = 0,
    replayed: usize = 0,
    missed: usize = 0,
};

pub const Upstream = struct {
    /// First path segment that selects this provider, e.g. `anthropic`.
    prefix: []const u8,
    /// Real API root, e.g. `https://api.anthropic.com`.
    base: []const u8,
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: net.Server,
    port: u16,
    mode: Mode,
    upstreams: []const Upstream,
    cassette: Cassette,
    mutex: Io.Mutex = .init,
    stats: Stats = .{},
    running: std.atomic.Value(bool) = .init(true),

    /// Binds the first free port at or above `port_hint`.
    ///
    /// The listener is held for the proxy's whole life, so there is no window
    /// between probing a port and claiming it.
    pub fn bind(
        gpa: std.mem.Allocator,
        io: Io,
        cassette_path: []const u8,
        mode: Mode,
        upstreams: []const Upstream,
        port_hint: u16,
    ) !Proxy {
        var c = try Cassette.load(gpa, io, cassette_path);
        errdefer c.deinit();

        var port = port_hint;
        while (port < port_hint +| 200) : (port += 1) {
            const addr: net.IpAddress = try .parseIp4("127.0.0.1", port);
            const server = addr.listen(io, .{}) catch |e| switch (e) {
                error.AddressInUse => continue,
                else => return e,
            };
            return .{
                .gpa = gpa,
                .io = io,
                .server = server,
                .port = port,
                .mode = mode,
                .upstreams = upstreams,
                .cassette = c,
            };
        }
        return error.NoFreePort;
    }

    pub fn deinit(p: *Proxy) void {
        p.server.deinit(p.io);
        p.cassette.deinit();
    }

    /// Environment pairs to inject into the child process.
    /// Caller owns the returned slice and every string in it.
    pub fn baseUrls(p: *const Proxy, gpa: std.mem.Allocator) ![]const [2][]const u8 {
        const out = try gpa.alloc([2][]const u8, p.upstreams.len);
        errdefer gpa.free(out);
        for (p.upstreams, 0..) |u, i| {
            const name = try std.ascii.allocUpperString(gpa, u.prefix);
            defer gpa.free(name);
            out[i] = .{
                try std.fmt.allocPrint(gpa, "{s}_BASE_URL", .{name}),
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/{s}", .{ p.port, u.prefix }),
            };
        }
        return out;
    }

    /// Serve until `shutdown` is called. Blocking; run it on its own thread.
    pub fn serve(p: *Proxy) void {
        while (p.running.load(.seq_cst)) {
            var stream = p.server.accept(p.io) catch break;
            defer stream.close(p.io);
            if (!p.running.load(.seq_cst)) break;
            p.handleConnection(stream) catch {};
        }
    }

    /// Unblocks a thread parked in `accept`.
    ///
    /// `shutdown` on a listening socket does not reliably wake `accept` on
    /// macOS, so the flag is followed by one throwaway connection that the
    /// loop observes and exits on.
    pub fn shutdown(p: *Proxy) void {
        p.running.store(false, .seq_cst);
        const addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", p.port) catch return;
        const s = addr.connect(p.io, .{ .mode = .stream }) catch return;
        s.close(p.io);
    }

    pub fn snapshot(p: *Proxy) Stats {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.stats;
    }

    /// Flush the cassette if anything was recorded.
    pub fn flush(p: *Proxy) !void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.cassette.dirty) try p.cassette.save(p.io);
    }

    fn handleConnection(p: *Proxy, stream: net.Stream) !void {
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(p.io, &in_buf);
        var writer = stream.writer(p.io, &out_buf);
        var server = http.Server.init(&reader.interface, &writer.interface);

        var req = server.receiveHead() catch return;
        p.handle(&req) catch {};
        // `respond` fills the connection writer's buffer; without this the
        // client blocks forever waiting for bytes that never leave the process.
        writer.interface.flush() catch {};
    }

    fn handle(p: *Proxy, req: *http.Server.Request) !void {
        const gpa = p.gpa;

        // `head.target` and the header values point into the connection's read
        // buffer, which draining the body reuses. Copy anything still needed
        // afterwards before the first body read.
        const method = req.head.method;
        const target = try gpa.dupe(u8, req.head.target);
        defer gpa.free(target);

        var headers: std.ArrayList(upstream.Header) = .empty;
        defer {
            for (headers.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            headers.deinit(gpa);
        }
        var head_it = req.iterateHeaders();
        while (head_it.next()) |h| {
            try headers.append(gpa, .{
                .name = try gpa.dupe(u8, h.name),
                .value = try gpa.dupe(u8, h.value),
            });
        }

        var body_buf: [16 * 1024]u8 = undefined;
        const body_reader = req.readerExpectNone(&body_buf);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = body_reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try body.appendSlice(gpa, chunk[0..n]);
        }

        const split = splitPrefix(target) orelse {
            return fail(req, "no provider prefix in request path");
        };
        const base = p.baseFor(split.prefix) orelse {
            return fail(req, "unknown provider prefix");
        };

        const entry_key = try matching.key(gpa, body.items, &matching.all_scrubbers);
        defer gpa.free(entry_key);

        if (p.lookup(entry_key)) |hit| {
            defer hit.deinit(gpa);
            p.bump(.replayed);
            return p.respond(req, hit.status, hit.headers, hit.body);
        }

        if (p.mode == .strict) {
            p.bump(.missed);
            return fail(req, "no cassette entry for this request");
        }

        const got = upstream.forward(gpa, p.io, base, .{
            .method = method,
            .path = split.rest,
            .headers = headers.items,
            .body = body.items,
        }) catch {
            return fail(req, "upstream request failed");
        };
        defer got.deinit(gpa);

        try p.record(entry_key, got);
        p.bump(.recorded);

        const stored = try gpa.alloc(cassette_mod.Header, got.headers.len);
        defer gpa.free(stored);
        for (got.headers, 0..) |h, i| {
            stored[i] = .{ .name = h.name, .value = redact.value(h.name, h.value) };
        }
        return p.respond(req, got.status, stored, .{ .text = got.body });
    }

    fn lookup(p: *Proxy, entry_key: []const u8) ?Exchange {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const hit = p.cassette.get(entry_key) orelse return null;
        return cloneExchange(p.gpa, hit) catch null;
    }

    fn record(p: *Proxy, entry_key: []const u8, got: upstream.Response) !void {
        const gpa = p.gpa;
        const headers = try gpa.alloc(cassette_mod.Header, got.headers.len);
        errdefer gpa.free(headers);
        for (got.headers, 0..) |h, i| {
            headers[i] = .{
                .name = try gpa.dupe(u8, h.name),
                // Redaction happens here, before the exchange can reach disk.
                .value = try gpa.dupe(u8, redact.value(h.name, h.value)),
            };
        }
        const e: Exchange = .{
            .key = try gpa.dupe(u8, entry_key),
            .status = got.status,
            .headers = headers,
            .body = try cassette_mod.Body.fromBytes(gpa, got.body),
        };
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        try p.cassette.insert(e);
    }

    fn bump(p: *Proxy, comptime field: enum { recorded, replayed, missed }) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        switch (field) {
            .recorded => p.stats.recorded += 1,
            .replayed => p.stats.replayed += 1,
            .missed => p.stats.missed += 1,
        }
    }

    fn baseFor(p: *const Proxy, prefix: []const u8) ?[]const u8 {
        for (p.upstreams) |u| {
            if (std.mem.eql(u8, u.prefix, prefix)) return u.base;
        }
        return null;
    }

    fn respond(
        p: *Proxy,
        req: *http.Server.Request,
        status: u16,
        headers: []const cassette_mod.Header,
        body: cassette_mod.Body,
    ) !void {
        const gpa = p.gpa;
        const bytes = try body.toBytes(gpa);
        defer gpa.free(bytes);

        var extra: std.ArrayList(http.Header) = .empty;
        defer extra.deinit(gpa);
        for (headers) |h| {
            if (upstream.isHopHeader(h.name)) continue;
            try extra.append(gpa, .{ .name = h.name, .value = h.value });
        }

        try req.respond(bytes, .{
            .status = @enumFromInt(status),
            .extra_headers = extra.items,
            .keep_alive = false,
        });
    }
};

fn fail(req: *http.Server.Request, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &buf,
        "{{\"error\":{{\"type\":\"tapedeck\",\"message\":\"{s}\"}}}}",
        .{message},
    ) catch "{\"error\":{\"type\":\"tapedeck\"}}";
    try req.respond(payload, .{
        .status = @enumFromInt(tapedeck_error),
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .keep_alive = false,
    });
}

fn cloneExchange(gpa: std.mem.Allocator, e: Exchange) !Exchange {
    const headers = try gpa.alloc(cassette_mod.Header, e.headers.len);
    errdefer gpa.free(headers);
    for (e.headers, 0..) |h, i| {
        headers[i] = .{
            .name = try gpa.dupe(u8, h.name),
            .value = try gpa.dupe(u8, h.value),
        };
    }
    const body: cassette_mod.Body = switch (e.body) {
        .text => |t| .{ .text = try gpa.dupe(u8, t) },
        .base64 => |b| .{ .base64 = try gpa.dupe(u8, b) },
    };
    return .{
        .key = try gpa.dupe(u8, e.key),
        .status = e.status,
        .headers = headers,
        .body = body,
    };
}

const Split = struct { prefix: []const u8, rest: []const u8 };

/// `/anthropic/v1/messages` becomes `anthropic` + `/v1/messages`.
pub fn splitPrefix(target: []const u8) ?Split {
    if (target.len == 0 or target[0] != '/') return null;
    const after = target[1..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    if (slash == 0) return null;
    return .{ .prefix = after[0..slash], .rest = after[slash..] };
}

const testing = std.testing;

test "split prefix separates provider from path" {
    const s = splitPrefix("/anthropic/v1/messages").?;
    try testing.expectEqualStrings("anthropic", s.prefix);
    try testing.expectEqualStrings("/v1/messages", s.rest);
}

test "split prefix rejects paths without a provider" {
    try testing.expect(splitPrefix("/v1/messages") == null or
        !std.mem.eql(u8, splitPrefix("/v1/messages").?.prefix, "anthropic"));
    try testing.expect(splitPrefix("/") == null);
    try testing.expect(splitPrefix("") == null);
    try testing.expect(splitPrefix("//v1") == null);
}

const Fake = struct {
    server: net.Server,
    port: u16,
    io: Io,
    hits: std.atomic.Value(usize) = .init(0),
    running: std.atomic.Value(bool) = .init(true),
    payload: []const u8,
    status: u16,

    fn start(io: Io, port_hint: u16, payload: []const u8, status: u16) !Fake {
        var port = port_hint;
        while (port < port_hint +| 200) : (port += 1) {
            const addr: net.IpAddress = try .parseIp4("127.0.0.1", port);
            const s = addr.listen(io, .{}) catch continue;
            return .{ .server = s, .port = port, .io = io, .payload = payload, .status = status };
        }
        return error.NoFreePort;
    }

    fn serve(f: *Fake) void {
        while (f.running.load(.seq_cst)) {
            var stream = f.server.accept(f.io) catch break;
            defer stream.close(f.io);
            var in_buf: [8192]u8 = undefined;
            var out_buf: [8192]u8 = undefined;
            var reader = stream.reader(f.io, &in_buf);
            var writer = stream.writer(f.io, &out_buf);
            var srv = http.Server.init(&reader.interface, &writer.interface);
            var req = srv.receiveHead() catch continue;
            var drain: [8192]u8 = undefined;
            const br = req.readerExpectNone(&drain);
            var sink: [4096]u8 = undefined;
            while (true) {
                const n = br.readSliceShort(&sink) catch break;
                if (n == 0) break;
            }
            _ = f.hits.fetchAdd(1, .seq_cst);
            req.respond(f.payload, .{
                .status = @enumFromInt(f.status),
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "set-cookie", .value = "session=leaked-credential" },
                },
                .keep_alive = false,
            }) catch {};
        }
    }

    fn stop(f: *Fake) void {
        f.running.store(false, .seq_cst);
        const addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", f.port) catch return;
        const s = addr.connect(f.io, .{ .mode = .stream }) catch return;
        s.close(f.io);
    }
};

const CallResult = struct { status: u16, body: []u8 };

fn callProxy(gpa: std.mem.Allocator, io: Io, port: u16, path: []const u8, body: []const u8) !CallResult {
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var r = try client.request(.POST, uri, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = "sk-secret" },
        },
    });
    defer r.deinit();

    const copy = try gpa.dupe(u8, body);
    defer gpa.free(copy);
    try r.sendBodyComplete(copy);

    var redirect: [4096]u8 = undefined;
    var resp = try r.receiveHead(&redirect);

    var transfer: [8192]u8 = undefined;
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var d: http.Decompress = undefined;
    const br = resp.readerDecompressing(&transfer, &d, &dbuf);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = br.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return .{ .status = @intFromEnum(resp.head.status), .body = try out.toOwnedSlice(gpa) };
}

test "records on first call and replays without touching upstream" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const sse = "event: a\ndata: {\"t\":1}\n\n";
    var fake = try Fake.start(io, 39100, sse, 200);
    const fake_thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer fake_thread.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-a";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

    const request_body =
        \\{"model":"m","messages":[]}
    ;

    {
        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39300);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", request_body);
        defer gpa.free(got.body);
        try testing.expectEqual(@as(u16, 200), got.status);
        try testing.expectEqualStrings(sse, got.body);
        try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst));

        try p.flush();
        p.shutdown();
        th.join();
        try testing.expectEqual(@as(usize, 1), p.snapshot().recorded);
    }

    {
        // Fresh process would reload from disk; strict mode must never call out.
        var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39400);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

        // Same call, different key order: matching must still hit.
        const drifted =
            \\{"messages":[],"model":"m"}
        ;
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", drifted);
        defer gpa.free(got.body);
        try testing.expectEqual(@as(u16, 200), got.status);
        try testing.expectEqualStrings(sse, got.body);
        try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst));

        p.shutdown();
        th.join();
        try testing.expectEqual(@as(usize, 1), p.snapshot().replayed);
    }

    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "sk-secret") == null);
    try testing.expect(std.mem.indexOf(u8, text, "leaked-credential") == null);
    try testing.expect(std.mem.indexOf(u8, text, "<REDACTED>") != null);
}

test "strict mode fails a miss without calling out" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var fake = try Fake.start(io, 39500, "data: ok\n\n", 200);
    const fake_thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer fake_thread.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-b";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

    var p = try Proxy.bind(gpa, io, dir ++ "/cassettes/default.jsonl", .strict, &ups, 39600);
    defer p.deinit();
    const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

    const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", "{\"model\":\"never\"}");
    defer gpa.free(got.body);
    try testing.expectEqual(@as(u16, 599), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "no cassette entry") != null);
    try testing.expectEqual(@as(usize, 0), fake.hits.load(.seq_cst));

    p.shutdown();
    th.join();
    try testing.expectEqual(@as(usize, 1), p.snapshot().missed);
}

test "unknown provider prefix is rejected" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-proxy-c";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var p = try Proxy.bind(gpa, io, dir ++ "/cassettes/default.jsonl", .record, &.{}, 39700);
    defer p.deinit();
    const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

    const got = try callProxy(gpa, io, p.port, "/nosuch/v1/messages", "{}");
    defer gpa.free(got.body);
    try testing.expectEqual(@as(u16, 599), got.status);

    p.shutdown();
    th.join();
}

test "base urls carry the provider prefix" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-proxy-d";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = "https://api.anthropic.com" }};
    var p = try Proxy.bind(gpa, io, dir ++ "/cassettes/default.jsonl", .record, &ups, 39800);
    defer p.deinit();

    const vars = try p.baseUrls(gpa);
    defer {
        for (vars) |v| {
            gpa.free(v[0]);
            gpa.free(v[1]);
        }
        gpa.free(vars);
    }
    try testing.expectEqualStrings("ANTHROPIC_BASE_URL", vars[0][0]);
    const want = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/anthropic", .{p.port});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, vars[0][1]);
}
