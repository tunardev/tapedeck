//! The loopback listener that records and replays.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const cassette_mod = @import("cassette.zig");
const matching = @import("matching.zig");
const redact = @import("redact.zig");
const upstream = @import("upstream.zig");
const usage_mod = @import("usage.zig");

const Cassette = cassette_mod.Cassette;
const Exchange = cassette_mod.Exchange;

/// Status returned for tapedeck's own failures.
///
/// Deliberately outside the range any provider uses, so a test that sees it
/// knows the tool failed rather than the API.
const tapedeck_error: u16 = 599;

/// Ceiling on in-flight connection workers. Well above any realistic test
/// runner's parallelism, low enough that a runaway client cannot exhaust threads.
const max_workers: usize = 64;

pub const Mode = enum {
    /// Replay a hit, call upstream on a miss.
    record,
    /// A miss is an error; never call out.
    strict,
    /// Ignore existing entries and refresh every key this run touches.
    /// Keys not seen are left alone, so refreshing one suite does not discard
    /// everything else on the cassette.
    rerecord,
};

pub const Stats = struct {
    recorded: usize = 0,
    replayed: usize = 0,
    missed: usize = 0,
    /// Requests tapedeck itself could not complete.
    failed: usize = 0,
    /// Tokens actually bought this run.
    spent_input: u64 = 0,
    spent_output: u64 = 0,
    /// Tokens a replay avoided buying.
    saved_input: u64 = 0,
    saved_output: u64 = 0,
};

pub const Upstream = struct {
    /// First path segment that selects this provider, e.g. `anthropic`.
    prefix: []const u8,
    /// Real API root, e.g. `https://api.anthropic.com`.
    base: []const u8,
    /// Environment variable the provider's SDK reads. Configured rather than
    /// derived, because vendors do not agree on the pattern — Gemini reads
    /// `GOOGLE_GEMINI_BASE_URL`, not `GEMINI_BASE_URL`.
    env: []const u8 = "",
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: net.Server,
    port: u16,
    mode: Mode,
    upstreams: []const Upstream,
    /// Dotted JSON paths excluded from the match key, from config.
    ignore: []const []const u8 = &.{},
    /// Store a hash of the request rather than the request itself.
    hash_keys: bool = false,
    /// When set, `rerecord` refreshes only the entry with this short id and
    /// replays everything else, so fixing one call costs one call.
    rerecord_id: ?[]const u8 = null,
    cassette: Cassette,
    mutex: Io.Mutex = .init,
    stats: Stats = .{},
    running: std.atomic.Value(bool) = .init(true),
    workers: std.atomic.Value(usize) = .init(0),

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
            const env_name = if (u.env.len > 0) try gpa.dupe(u8, u.env) else blk: {
                const upper = try std.ascii.allocUpperString(gpa, u.prefix);
                defer gpa.free(upper);
                break :blk try std.fmt.allocPrint(gpa, "{s}_BASE_URL", .{upper});
            };
            out[i] = .{
                env_name,
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/{s}", .{ p.port, u.prefix }),
            };
        }
        return out;
    }

    /// Serve until `shutdown` is called. Blocking; run it on its own thread.
    ///
    /// One worker per connection: a test runner with parallel workers issues
    /// concurrent calls, and handling them inline would serialise every one
    /// behind the slowest upstream response.
    pub fn serve(p: *Proxy) void {
        while (p.running.load(.seq_cst)) {
            const stream = p.server.accept(p.io) catch |e| switch (e) {
                // Transient: a peer that hung up before we accepted, or a
                // momentary fd shortage. Ending the loop here would leave the
                // listener open and every later request hanging.
                error.ConnectionAborted,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                => continue,
                else => break,
            };
            if (!p.running.load(.seq_cst)) {
                stream.close(p.io);
                break;
            }
            if (p.workers.fetchAdd(1, .seq_cst) < max_workers) {
                if (std.Thread.spawn(.{}, work, .{ p, stream })) |th| {
                    th.detach();
                    continue;
                } else |_| {}
            }
            // At the cap, or out of threads: handle it here rather than drop it.
            _ = p.workers.fetchSub(1, .seq_cst);
            p.handleConnection(stream) catch {};
            stream.close(p.io);
        }
        // Returning while workers still hold `p` would let the caller free it
        // underneath them.
        while (p.workers.load(.seq_cst) > 0) {
            p.io.sleep(.fromMilliseconds(1), .awake) catch break;
        }
    }

    fn work(p: *Proxy, stream: net.Stream) void {
        defer _ = p.workers.fetchSub(1, .seq_cst);
        defer stream.close(p.io);
        p.handleConnection(stream) catch {};
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

        // `head.target` and the header values point into the connection read
        // buffer, which draining the body reuses. Copy anything needed after
        // that read before the first one.
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

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        if (method.requestHasBody()) {
            var body_buf: [16 * 1024]u8 = undefined;
            // curl sends `Expect: 100-continue` for larger bodies, and
            // `readerExpectNone` asserts the header is absent.
            const body_reader = if (req.head.expect != null)
                try req.readerExpectContinue(&body_buf)
            else
                req.readerExpectNone(&body_buf);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = body_reader.readSliceShort(&chunk) catch {
                    p.bump(.failed);
                    return fail(req, "client request body was truncated");
                };
                if (n == 0) break;
                try body.appendSlice(gpa, chunk[0..n]);
            }
        }

        const split = splitPrefix(target) orelse {
            p.bump(.failed);
            return fail(req, "no provider prefix in request path");
        };
        const base = p.baseFor(split.prefix) orelse {
            p.bump(.failed);
            return fail(req, "unknown provider prefix");
        };

        // The body alone is not an identity: two bodyless POSTs to different
        // paths would otherwise share one cassette entry.
        const canonical = try matching.key(gpa, .{
            .method = @tagName(method),
            .provider = split.prefix,
            .path = split.rest,
        }, body.items, .{ .ignore = p.ignore });
        defer gpa.free(canonical);

        const entry_key = if (p.hash_keys)
            try cassette_mod.hashKey(gpa, canonical)
        else
            try gpa.dupe(u8, canonical);
        defer gpa.free(entry_key);

        if (!p.shouldRefresh(entry_key)) {
            if (p.lookup(entry_key)) |hit| {
                defer hit.deinit(gpa);
                p.bump(.replayed);
                p.addTokens(.saved, hit.input_tokens, hit.output_tokens);
                return p.respond(req, hit.status, hit.headers, hit.body, hit.chunked);
            }
            if (p.mode == .strict) {
                p.bump(.missed);
                return fail(req, "no cassette entry for this request");
            }
        }

        const got = upstream.forward(gpa, p.io, base, .{
            .method = method,
            .path = split.rest,
            .headers = headers.items,
            .body = body.items,
        }) catch |e| {
            p.bump(.failed);
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "upstream request failed: {s}", .{@errorName(e)}) catch
                "upstream request failed";
            return fail(req, msg);
        };
        defer got.deinit(gpa);

        const u = usage_mod.parse(gpa, got.body);
        try p.record(entry_key, got, u);
        p.bump(.recorded);
        p.addTokens(.spent, u.input, u.output);

        const stored = try gpa.alloc(cassette_mod.Header, got.headers.len);
        defer gpa.free(stored);
        for (got.headers, 0..) |h, i| {
            stored[i] = .{ .name = h.name, .value = redact.value(h.name, h.value) };
        }
        return p.respond(req, got.status, stored, .{ .text = got.body }, got.chunked);
    }

    /// Whether this key must go upstream regardless of what is on the cassette.
    fn shouldRefresh(p: *const Proxy, entry_key: []const u8) bool {
        if (p.mode != .rerecord) return false;
        const want = p.rerecord_id orelse return true;
        return std.mem.eql(u8, &cassette_mod.shortId(entry_key), want);
    }

    fn lookup(p: *Proxy, entry_key: []const u8) ?Exchange {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const hit = p.cassette.get(entry_key) orelse return null;
        return cloneExchange(p.gpa, hit) catch null;
    }

    fn addTokens(p: *Proxy, comptime which: enum { spent, saved }, input: u64, output: u64) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        switch (which) {
            .spent => {
                p.stats.spent_input += input;
                p.stats.spent_output += output;
            },
            .saved => {
                p.stats.saved_input += input;
                p.stats.saved_output += output;
            },
        }
    }

    fn record(p: *Proxy, entry_key: []const u8, got: upstream.Response, u: usage_mod.Usage) !void {
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
            .chunked = got.chunked,
            .input_tokens = u.input,
            .output_tokens = u.output,
            .model = try gpa.dupe(u8, u.model),
        };
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        try p.cassette.insert(e);
    }

    fn bump(p: *Proxy, comptime field: enum { recorded, replayed, missed, failed }) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        switch (field) {
            .recorded => p.stats.recorded += 1,
            .replayed => p.stats.replayed += 1,
            .missed => p.stats.missed += 1,
            .failed => p.stats.failed += 1,
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
        chunked: bool,
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

        if (chunked) {
            var out_buf: [16 * 1024]u8 = undefined;
            var w = try req.respondStreaming(&out_buf, .{
                .respond_options = .{
                    .status = @enumFromInt(status),
                    .extra_headers = extra.items,
                    .keep_alive = false,
                },
            });
            try w.writer.writeAll(bytes);
            try w.end();
        } else {
            try req.respond(bytes, .{
                .status = @enumFromInt(status),
                .extra_headers = extra.items,
                .keep_alive = false,
            });
        }
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
        .chunked = e.chunked,
        .input_tokens = e.input_tokens,
        .output_tokens = e.output_tokens,
        .model = try gpa.dupe(u8, e.model),
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

test "split prefix takes the first segment as the provider" {
    // `/v1/messages` is not rejected: `v1` becomes the provider and is then
    // refused by `baseFor` because no such provider is configured.
    const s = splitPrefix("/v1/messages").?;
    try testing.expectEqualStrings("v1", s.prefix);
    try testing.expectEqualStrings("/messages", s.rest);
}

test "split prefix rejects paths with no segments" {
    try testing.expect(splitPrefix("/") == null);
    try testing.expect(splitPrefix("") == null);
    try testing.expect(splitPrefix("//v1") == null);
    try testing.expect(splitPrefix("no-leading-slash") == null);
}

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
            // Concurrent, or the stub itself serialises what the proxy just
            // parallelised and the timing assertion measures the wrong thing.
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
    // Deriving GEMINI_BASE_URL from the prefix would be wrong.
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
        // Distinct bodies so every request is a cache miss and must reach the
        // provider; identical bodies would replay and hide serialisation.
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
    const started = Io.Timestamp.now(io, .awake);
    for (0..n) |i| {
        callers[i] = .{ .gpa = gpa, .io = io, .port = p.port, .index = i };
        threads[i] = try std.Thread.spawn(.{}, ConcurrentCaller.call, .{&callers[i]});
    }
    for (&threads) |*th| th.join();
    const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds, 1_000_000);

    for (callers) |c| try testing.expect(c.ok);
    try testing.expectEqual(@as(usize, n), fake.hits.load(.seq_cst));

    p.shutdown();
    serving.join();

    // Serial handling costs n*300ms; concurrent costs roughly one delay. The
    // midpoint leaves generous headroom for a loaded CI runner.
    try testing.expect(elapsed_ms < 800);
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
        // A 429 is data a suite may assert on, not a transport failure.
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
        // The replay must be framed the way the recording was.
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

    // First recording, from a provider returning "old".
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

    // The prompt's answer changed upstream; rerecord must go and fetch it.
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

    // And the refreshed answer is what replays afterwards.
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

    // Replay must still hit, or the privacy option would cost correctness.
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

    // Take the id of the first entry only.
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
    // The whole point: fixing one call costs one call, not the whole suite.
    try testing.expectEqual(@as(usize, 1), stats.recorded);
    try testing.expectEqual(@as(usize, 1), stats.replayed);
    try testing.expectEqual(@as(usize, 1), fake.hits.load(.seq_cst) - before);
}
