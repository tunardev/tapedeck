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

const tapedeck_error: u16 = 599;

const max_workers: usize = 64;

pub const Mode = enum {
    record,
    strict,
    rerecord,
};

pub const Stats = struct {
    recorded: usize = 0,
    replayed: usize = 0,
    missed: usize = 0,
    failed: usize = 0,
    spent_input: u64 = 0,
    spent_output: u64 = 0,
    saved_input: u64 = 0,
    saved_output: u64 = 0,
};

pub const Upstream = struct {
    prefix: []const u8,
    base: []const u8,
    env: []const u8 = "",
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: net.Server,
    port: u16,
    mode: Mode,
    upstreams: []const Upstream,
    ignore: []const []const u8 = &.{},
    hash_keys: bool = false,
    rerecord_id: ?[]const u8 = null,
    cassette: Cassette,
    mutex: Io.Mutex = .init,
    stats: Stats = .{},
    running: std.atomic.Value(bool) = .init(true),
    workers: std.atomic.Value(usize) = .init(0),

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

    pub fn serve(p: *Proxy) void {
        while (p.running.load(.seq_cst)) {
            const stream = p.server.accept(p.io) catch |e| switch (e) {
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
            _ = p.workers.fetchSub(1, .seq_cst);
            p.handleConnection(stream) catch {};
            stream.close(p.io);
        }
        while (p.workers.load(.seq_cst) > 0) {
            p.io.sleep(.fromMilliseconds(1), .awake) catch break;
        }
    }

    fn work(p: *Proxy, stream: net.Stream) void {
        defer _ = p.workers.fetchSub(1, .seq_cst);
        defer stream.close(p.io);
        p.handleConnection(stream) catch {};
    }

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
        writer.interface.flush() catch {};
    }

    fn handle(p: *Proxy, req: *http.Server.Request) !void {
        const gpa = p.gpa;

        var incoming = p.capture(req) catch |e| switch (e) {
            error.TruncatedRequestBody => {
                p.bump(.failed);
                return fail(req, "client request body was truncated");
            },
            else => return e,
        };
        defer incoming.deinit(gpa);

        const split = splitPrefix(incoming.target) orelse {
            p.bump(.failed);
            return fail(req, "no provider prefix in request path");
        };
        const base = p.baseFor(split.prefix) orelse {
            p.bump(.failed);
            return fail(req, "unknown provider prefix");
        };

        const entry_key = try p.keyFor(incoming, split);
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

        return p.fetchAndRecord(req, incoming, split, entry_key, base);
    }

    const Incoming = struct {
        method: http.Method,
        target: []const u8,
        headers: []upstream.Header,
        body: []u8,

        fn deinit(in: *Incoming, gpa: std.mem.Allocator) void {
            gpa.free(in.target);
            for (in.headers) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            gpa.free(in.headers);
            gpa.free(in.body);
        }
    };

    fn capture(p: *Proxy, req: *http.Server.Request) !Incoming {
        const gpa = p.gpa;
        const method = req.head.method;

        const target = try gpa.dupe(u8, req.head.target);
        errdefer gpa.free(target);

        var headers: std.ArrayList(upstream.Header) = .empty;
        errdefer {
            for (headers.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            headers.deinit(gpa);
        }
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            const name = try gpa.dupe(u8, h.name);
            errdefer gpa.free(name);
            try headers.append(gpa, .{ .name = name, .value = try gpa.dupe(u8, h.value) });
        }

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(gpa);
        if (method.requestHasBody()) try readBody(gpa, req, &body);

        return .{
            .method = method,
            .target = target,
            .headers = try headers.toOwnedSlice(gpa),
            .body = try body.toOwnedSlice(gpa),
        };
    }

    fn readBody(gpa: std.mem.Allocator, req: *http.Server.Request, out: *std.ArrayList(u8)) !void {
        var buf: [16 * 1024]u8 = undefined;
        const reader = if (req.head.expect != null)
            try req.readerExpectContinue(&buf)
        else
            req.readerExpectNone(&buf);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk) catch return error.TruncatedRequestBody;
            if (n == 0) break;
            try out.appendSlice(gpa, chunk[0..n]);
        }
    }

    fn keyFor(p: *Proxy, in: Incoming, split: Split) ![]u8 {
        const gpa = p.gpa;
        const canonical = try matching.key(gpa, .{
            .method = @tagName(in.method),
            .provider = split.prefix,
            .path = split.rest,
        }, in.body, .{ .ignore = p.ignore });
        if (!p.hash_keys) return canonical;
        defer gpa.free(canonical);
        return cassette_mod.hashKey(gpa, canonical);
    }

    fn fetchAndRecord(
        p: *Proxy,
        req: *http.Server.Request,
        in: Incoming,
        split: Split,
        entry_key: []const u8,
        base: []const u8,
    ) !void {
        const gpa = p.gpa;
        const got = upstream.forward(gpa, p.io, base, .{
            .method = in.method,
            .path = split.rest,
            .headers = in.headers,
            .body = in.body,
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
