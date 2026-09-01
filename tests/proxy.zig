const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const tapedeck = @import("tapedeck");
const cassette_mod = tapedeck.cassette;
const proxy_mod = tapedeck.proxy;

const Cassette = cassette_mod.Cassette;
const Mode = proxy_mod.Mode;
const Proxy = proxy_mod.Proxy;
const Upstream = proxy_mod.Upstream;
const testing = std.testing;

const Fake = struct {
    server: net.Server,
    port: u16,
    io: Io,
    hits: std.atomic.Value(usize) = .init(0),
    running: std.atomic.Value(bool) = .init(true),
    workers: std.atomic.Value(usize) = .init(0),
    payload: []const u8,
    status: u16,
    delay_ms: u64 = 0,
    chunked: bool = false,
    inflight: std.atomic.Value(usize) = .init(0),
    peak_inflight: std.atomic.Value(usize) = .init(0),

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
            const stream = f.server.accept(f.io) catch break;
            if (!f.running.load(.seq_cst)) {
                stream.close(f.io);
                break;
            }
            _ = f.inflight.fetchAdd(1, .seq_cst);
            if (std.Thread.spawn(.{}, Fake.handle, .{ f, stream })) |th| {
                th.detach();
            } else |_| {
                _ = f.inflight.fetchSub(1, .seq_cst);
                stream.close(f.io);
            }
        }
        while (f.inflight.load(.seq_cst) > 0) {
            f.io.sleep(.fromMilliseconds(1), .awake) catch break;
        }
    }

    fn handle(f: *Fake, stream: net.Stream) void {
        defer _ = f.inflight.fetchSub(1, .seq_cst);
        f.recordPeak();
        defer stream.close(f.io);
        var in_buf: [8192]u8 = undefined;
        var out_buf: [8192]u8 = undefined;
        var reader = stream.reader(f.io, &in_buf);
        var writer = stream.writer(f.io, &out_buf);
        var srv = http.Server.init(&reader.interface, &writer.interface);
        var req = srv.receiveHead() catch return;
        var drain: [8192]u8 = undefined;
        const br = req.readerExpectNone(&drain);
        var sink: [4096]u8 = undefined;
        while (true) {
            const n = br.readSliceShort(&sink) catch break;
            if (n == 0) break;
        }
        _ = f.hits.fetchAdd(1, .seq_cst);
        if (f.delay_ms > 0) f.io.sleep(.fromMilliseconds(@intCast(f.delay_ms)), .awake) catch {};
        const hdrs = [_]http.Header{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "set-cookie", .value = "session=leaked-credential" },
        };
        if (f.chunked) {
            var body_buf: [8192]u8 = undefined;
            if (req.respondStreaming(&body_buf, .{
                .respond_options = .{
                    .status = @enumFromInt(f.status),
                    .extra_headers = &hdrs,
                    .keep_alive = false,
                },
            })) |bw_val| {
                var bw = bw_val;
                bw.writer.writeAll(f.payload) catch {};
                bw.end() catch {};
            } else |_| {}
        } else {
            req.respond(f.payload, .{
                .status = @enumFromInt(f.status),
                .extra_headers = &hdrs,
                .keep_alive = false,
            }) catch {};
        }
        writer.interface.flush() catch {};
    }

    fn recordPeak(f: *Fake) void {
        const now = f.inflight.load(.seq_cst);
        var seen = f.peak_inflight.load(.seq_cst);
        while (now > seen) {
            seen = f.peak_inflight.cmpxchgWeak(seen, now, .seq_cst, .seq_cst) orelse break;
        }
    }

    fn stop(f: *Fake) void {
        f.running.store(false, .seq_cst);
        const addr: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", f.port) catch return;
        const s = addr.connect(f.io, .{ .mode = .stream }) catch return;
        s.close(f.io);
    }
};

const CallResult = struct { status: u16, body: []u8, chunked: bool };

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
    return .{
        .status = @intFromEnum(resp.head.status),
        .body = try out.toOwnedSlice(gpa),
        .chunked = resp.head.content_length == null,
    };
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
        var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39400);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

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

test "a configured env name overrides the derived one" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-proxy-envname";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const ups = [_]Upstream{.{
        .prefix = "gemini",
        .base = "https://generativelanguage.googleapis.com",
        .env = "GOOGLE_GEMINI_BASE_URL",
    }};
    var p = try Proxy.bind(gpa, io, dir ++ "/cassettes/default.jsonl", .record, &ups, 39890);
    defer p.deinit();

    const vars = try p.baseUrls(gpa);
    defer {
        for (vars) |v| {
            gpa.free(v[0]);
            gpa.free(v[1]);
        }
        gpa.free(vars);
    }
    try testing.expectEqualStrings("GOOGLE_GEMINI_BASE_URL", vars[0][0]);
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

const ConcurrentCaller = struct {
    gpa: std.mem.Allocator,
    io: Io,
    port: u16,
    index: usize,
    ok: bool = false,

    fn call(c: *ConcurrentCaller) void {
        var buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"model\":\"m\",\"n\":{d}}}", .{c.index}) catch return;
        const got = callProxy(c.gpa, c.io, c.port, "/anthropic/v1/messages", body) catch return;
        defer c.gpa.free(got.body);
        c.ok = got.status == 200;
    }
};

test "concurrent requests are not serialised behind each other" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var fake = try Fake.start(io, 39900, "data: ok\n\n", 200);
    fake.delay_ms = 300;
    const fake_thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer fake_thread.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-conc";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

    var p = try Proxy.bind(gpa, io, dir ++ "/cassettes/default.jsonl", .record, &ups, 39950);
    defer p.deinit();
    const serving = try std.Thread.spawn(.{}, Proxy.serve, .{&p});

    const n = 4;
    var callers: [n]ConcurrentCaller = undefined;
    var threads: [n]std.Thread = undefined;

    for (0..n) |i| {
        callers[i] = .{ .gpa = gpa, .io = io, .port = p.port, .index = i };
        threads[i] = try std.Thread.spawn(.{}, ConcurrentCaller.call, .{&callers[i]});
    }
    for (&threads) |*th| th.join();

    for (callers) |c| try testing.expect(c.ok);
    try testing.expectEqual(@as(usize, n), fake.hits.load(.seq_cst));

    p.shutdown();
    serving.join();

    try testing.expect(fake.peak_inflight.load(.seq_cst) >= 2);
}

test "error status and body round trip exactly" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const envelope =
        \\{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}
    ;
    var fake = try Fake.start(io, 39960, envelope, 429);
    const fake_thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer fake_thread.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-err";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};
    const body =
        \\{"model":"m","messages":[]}
    ;

    {
        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39970);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqual(@as(u16, 429), got.status);
        try testing.expectEqualStrings(envelope, got.body);
        try p.flush();
        p.shutdown();
        th.join();
    }
    {
        var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39980);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqual(@as(u16, 429), got.status);
        try testing.expectEqualStrings(envelope, got.body);
        try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst));
        p.shutdown();
        th.join();
    }
}

test "a streamed response replays as streamed" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const sse = "event: a\ndata: {\"t\":1}\n\n";
    var fake = try Fake.start(io, 39810, sse, 200);
    fake.chunked = true;
    const fake_thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer fake_thread.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-chunked";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};
    const body =
        \\{"model":"m","messages":[]}
    ;

    {
        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39820);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqualStrings(sse, got.body);
        try testing.expect(got.chunked);
        try p.flush();
        p.shutdown();
        th.join();
    }

    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"chunked\":true") != null);

    {
        var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39830);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqualStrings(sse, got.body);
        try testing.expect(got.chunked);
        p.shutdown();
        th.join();
    }
}

test "rerecord refreshes an entry instead of replaying it" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-proxy-rerec";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";
    const body =
        \\{"model":"m","messages":[]}
    ;

    {
        var fake = try Fake.start(io, 39840, "data: old\n\n", 200);
        const ft = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
        defer ft.join();
        defer fake.stop();
        const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
        defer gpa.free(base);
        const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39850);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqualStrings("data: old\n\n", got.body);
        try p.flush();
        p.shutdown();
        th.join();
    }

    {
        var fake = try Fake.start(io, 39860, "data: new\n\n", 200);
        const ft = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
        defer ft.join();
        defer fake.stop();
        const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
        defer gpa.free(base);
        const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

        var p = try Proxy.bind(gpa, io, path, .rerecord, &ups, 39870);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqualStrings("data: new\n\n", got.body);
        try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst));
        try p.flush();
        p.shutdown();
        th.join();
    }

    {
        const ups = [_]Upstream{.{ .prefix = "anthropic", .base = "http://127.0.0.1:1" }};
        var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39880);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try testing.expectEqualStrings("data: new\n\n", got.body);
        p.shutdown();
        th.join();
    }
}

test "hash_keys keeps the prompt out of the cassette" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var fake = try Fake.start(io, 39710, "data: ok\n\n", 200);
    const ft = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer ft.join();
    defer fake.stop();

    const dir = ".tapedeck-proxy-hashed";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};
    const body =
        \\{"messages":[{"role":"user","content":"PROPRIETARY PROMPT TEXT"}]}
    ;

    {
        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39720);
        p.hash_keys = true;
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
        defer gpa.free(got.body);
        try p.flush();
        p.shutdown();
        th.join();
    }

    const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "PROPRIETARY PROMPT TEXT") == null);

    var p = try Proxy.bind(gpa, io, path, .strict, &ups, 39730);
    p.hash_keys = true;
    defer p.deinit();
    const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
    const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", body);
    defer gpa.free(got.body);
    try testing.expectEqualStrings("data: ok\n\n", got.body);
    p.shutdown();
    th.join();
    try testing.expectEqual(@as(usize, 1), p.snapshot().replayed);
}

test "a rerecord selector refreshes one entry and replays the rest" {
    const gpa = testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    const dir = ".tapedeck-proxy-select";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/cassettes/default.jsonl";
    const first =
        \\{"model":"m","n":1}
    ;
    const second =
        \\{"model":"m","n":2}
    ;

    var fake = try Fake.start(io, 39740, "data: ok\n\n", 200);
    const ft = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer ft.join();
    defer fake.stop();
    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    const ups = [_]Upstream{.{ .prefix = "anthropic", .base = base }};

    {
        var p = try Proxy.bind(gpa, io, path, .record, &ups, 39750);
        defer p.deinit();
        const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
        for ([_][]const u8{ first, second }) |b| {
            const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", b);
            gpa.free(got.body);
        }
        try p.flush();
        p.shutdown();
        th.join();
    }

    var loaded = try Cassette.load(gpa, io, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.count());
    const target = cassette_mod.shortId(loaded.values()[0].key);

    const before = fake.hits.load(.seq_cst);
    var p = try Proxy.bind(gpa, io, path, .rerecord, &ups, 39760);
    p.rerecord_id = &target;
    defer p.deinit();
    const th = try std.Thread.spawn(.{}, Proxy.serve, .{&p});
    for ([_][]const u8{ first, second }) |b| {
        const got = try callProxy(gpa, io, p.port, "/anthropic/v1/messages", b);
        gpa.free(got.body);
    }
    p.shutdown();
    th.join();

    const stats = p.snapshot();
    try testing.expectEqual(@as(usize, 1), stats.recorded);
    try testing.expectEqual(@as(usize, 1), stats.replayed);
    try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst) - before);
}
