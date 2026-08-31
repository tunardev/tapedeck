const std = @import("std");
const Io = std.Io;
const tapedeck = @import("tapedeck");

const cassette_mod = tapedeck.cassette;
const matching = tapedeck.matching;
const proxy_mod = tapedeck.proxy;
const runner = tapedeck.runner;
const paths_mod = tapedeck.paths;
const config_mod = tapedeck.config;
const Paths = paths_mod.Paths;

const usage =
    \\tapedeck — record your LLM calls once, replay them free
    \\
    \\usage:
    \\  tapedeck [options] -- <command>   run <command> with recording enabled
    \\  tapedeck ls                       list recorded cassettes
    \\  tapedeck show [name]              print the exchanges on a cassette
    \\  tapedeck where                    print the cassette directory
    \\  tapedeck key <body>               print the match key for a request body
    \\  tapedeck --version
    \\
    \\options:
    \\  --strict            a request with no recorded entry is an error
    \\  --rerecord          refresh every entry this run touches
    \\  --cassette <name>   cassette to use (default: $TAPEDECK_CASSETTE or "default")
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| try argv.append(gpa, a);

    var mode: proxy_mod.Mode = .record;
    var name: []const u8 = env.get("TAPEDECK_CASSETTE") orelse "default";

    var i: usize = 0;
    while (i < argv.items.len) : (i += 1) {
        const a = argv.items[i];
        if (std.mem.eql(u8, a, "--")) {
            return wrap(gpa, io, env, argv.items[i + 1 ..], mode, name);
        } else if (std.mem.eql(u8, a, "--strict")) {
            mode = .strict;
        } else if (std.mem.eql(u8, a, "--rerecord")) {
            mode = .rerecord;
        } else if (std.mem.eql(u8, a, "--cassette")) {
            i += 1;
            if (i >= argv.items.len) return fail(io, "--cassette needs a name");
            name = argv.items[i];
        } else if (std.mem.eql(u8, a, "--version")) {
            return printLine(io, "tapedeck 0.1.0");
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return printLine(io, usage);
        } else if (std.mem.eql(u8, a, "where")) {
            const p = try Paths.resolve(gpa, env);
            defer p.deinit(gpa);
            const dir = try p.cassetteFile(gpa, "");
            defer gpa.free(dir);
            return printLine(io, dir);
        } else if (std.mem.eql(u8, a, "key")) {
            i += 1;
            if (i >= argv.items.len) return fail(io, "key needs a request body");
            const k = try matching.key(gpa, argv.items[i], &matching.all_scrubbers, &.{});
            defer gpa.free(k);
            return printLine(io, k);
        } else if (std.mem.eql(u8, a, "ls")) {
            return list(gpa, io, env);
        } else if (std.mem.eql(u8, a, "show")) {
            if (i + 1 < argv.items.len) name = argv.items[i + 1];
            return show(gpa, io, env, name);
        } else {
            return fail(io, usage);
        }
    }
    return fail(io, usage);
}

fn cassettePath(
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    io: Io,
    name: []const u8,
) ![]u8 {
    const safe = paths_mod.sanitizeName(name) orelse
        fail(io, "cassette name must be a single path segment");
    const p = try Paths.resolve(gpa, env);
    defer p.deinit(gpa);
    const file = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{safe});
    defer gpa.free(file);
    return p.cassetteFile(gpa, file);
}

fn wrap(
    gpa: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    command: []const []const u8,
    mode: proxy_mod.Mode,
    name: []const u8,
) !void {
    if (command.len == 0) return fail(io, "nothing to run; try `tapedeck -- pytest`");

    const path = try cassettePath(gpa, env, io, name);
    defer gpa.free(path);

    const home = try Paths.resolve(gpa, env);
    defer home.deinit(gpa);
    var cfg = config_mod.Config.load(gpa, io, home.root) catch |e| switch (e) {
        error.MalformedConfig => return fail(io, "config.json is not valid tapedeck config"),
        else => return e,
    };
    defer cfg.deinit();

    var upstreams: std.ArrayList(proxy_mod.Upstream) = .empty;
    defer {
        for (upstreams.items) |u| gpa.free(u.base);
        upstreams.deinit(gpa);
    }
    for (cfg.providers) |prov| {
        // Per-provider override so a test can point at a local stub with no
        // network and no key.
        const upper = try std.ascii.allocUpperString(gpa, prov.name);
        defer gpa.free(upper);
        const var_name = try std.fmt.allocPrint(gpa, "TAPEDECK_{s}_UPSTREAM", .{upper});
        defer gpa.free(var_name);
        const base = env.get(var_name) orelse prov.base;
        try upstreams.append(gpa, .{
            .prefix = prov.name,
            .base = try gpa.dupe(u8, base),
            .env = prov.env,
        });
    }

    var proxy = try proxy_mod.Proxy.bind(gpa, io, path, mode, upstreams.items, 39000);
    proxy.ignore = cfg.ignore;
    defer proxy.deinit();

    const injected = try proxy.baseUrls(gpa);
    defer {
        for (injected) |v| {
            gpa.free(v[0]);
            gpa.free(v[1]);
        }
        gpa.free(injected);
    }

    const serving = try std.Thread.spawn(.{}, proxy_mod.Proxy.serve, .{&proxy});
    const code = runner.run(io, command, env, injected) catch |e| {
        proxy.shutdown();
        serving.join();
        return e;
    };
    proxy.shutdown();
    serving.join();
    try proxy.flush();

    const stats = proxy.snapshot();
    var buf: [256]u8 = undefined;
    const verb = switch (mode) {
        .record => "recording",
        .strict => "replaying",
        .rerecord => "re-recording",
    };
    const line = std.fmt.bufPrint(
        &buf,
        "  {s} · {d} recorded · {d} replayed · {d} missed\n",
        .{ verb, stats.recorded, stats.replayed, stats.missed },
    ) catch "  done\n";
    printErr(io, line);

    std.process.exit(code);
}

fn list(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const p = try Paths.resolve(gpa, env);
    defer p.deinit(gpa);
    const dir_path = try p.cassetteFile(gpa, "");
    defer gpa.free(dir_path);

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return printLine(io, "no cassettes recorded yet");
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var walker = dir.iterate();
    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const full = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(full);
        var c = cassette_mod.Cassette.load(gpa, io, full) catch continue;
        defer c.deinit();
        const stat = dir.statFile(io, entry.name, .{}) catch null;
        const bytes: u64 = if (stat) |st| st.size else 0;
        const name = entry.name[0 .. entry.name.len - ".jsonl".len];
        var row: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&row, "{s: <24} {d: >5} entries  {d: >8} bytes\n", .{
            name, c.count(), bytes,
        });
        try out.appendSlice(gpa, text);
        found += 1;
    }
    if (found == 0) return printLine(io, "no cassettes recorded yet");
    printRaw(io, out.items);
}

fn show(gpa: std.mem.Allocator, io: Io, env: *std.process.Environ.Map, name: []const u8) !void {
    const path = try cassettePath(gpa, env, io, name);
    defer gpa.free(path);

    var c = cassette_mod.Cassette.load(gpa, io, path) catch {
        return fail(io, "no such cassette");
    };
    defer c.deinit();

    if (c.count() == 0) return printLine(io, "cassette is empty");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (c.values()) |e| {
        var head: [256]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&head, "status {d}{s}\n", .{
            e.status,
            if (e.chunked) " (streamed)" else "",
        }));
        for (e.headers) |h| {
            var hb: [1024]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&hb, "  {s}: {s}\n", .{ h.name, h.value }));
        }
        const body = try e.body.toBytes(gpa);
        defer gpa.free(body);
        try out.appendSlice(gpa, body);
        try out.appendSlice(gpa, "\n---\n");
    }
    printRaw(io, out.items);
}

fn printRaw(io: Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

fn printLine(io: Io, text: []const u8) void {
    printRaw(io, text);
    if (text.len == 0 or text[text.len - 1] != '\n') printRaw(io, "\n");
}

fn printErr(io: Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

fn fail(io: Io, message: []const u8) noreturn {
    printErr(io, message);
    if (message.len == 0 or message[message.len - 1] != '\n') printErr(io, "\n");
    std.process.exit(2);
}
