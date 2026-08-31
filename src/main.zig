const std = @import("std");
const Io = std.Io;
const tapedeck = @import("tapedeck");

const matching = tapedeck.matching;
const proxy_mod = tapedeck.proxy;
const runner = tapedeck.runner;
const Paths = tapedeck.paths.Paths;

const usage =
    \\tapedeck — record your LLM calls once, replay them free
    \\
    \\usage:
    \\  tapedeck [--strict] -- <command>   run <command> with recording enabled
    \\  tapedeck where                     print the resolved cassette directory
    \\  tapedeck key <body>                print the match key for a request body
    \\  tapedeck --version
    \\
;

/// Providers tapedeck fronts, and the environment variable each SDK reads.
///
/// The upstream is overridable so tests can point at a local fake without a
/// network or a key.
const providers = [_]struct { prefix: []const u8, override: []const u8, default: []const u8 }{
    .{ .prefix = "anthropic", .override = "TAPEDECK_ANTHROPIC_UPSTREAM", .default = "https://api.anthropic.com" },
    .{ .prefix = "openai", .override = "TAPEDECK_OPENAI_UPSTREAM", .default = "https://api.openai.com" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| try argv.append(gpa, a);

    var strict = false;
    var i: usize = 0;
    while (i < argv.items.len) : (i += 1) {
        const a = argv.items[i];
        if (std.mem.eql(u8, a, "--")) {
            return wrap(gpa, io, env, argv.items[i + 1 ..], strict);
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
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
            if (i + 1 >= argv.items.len) return fail(io, "key needs a request body");
            const k = try matching.key(gpa, argv.items[i + 1], &matching.all_scrubbers);
            defer gpa.free(k);
            return printLine(io, k);
        } else {
            return fail(io, usage);
        }
    }
    return fail(io, usage);
}

fn wrap(
    gpa: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    command: []const []const u8,
    strict: bool,
) !void {
    if (command.len == 0) return fail(io, "nothing to run; try `tapedeck -- pytest`");

    const p = try Paths.resolve(gpa, env);
    defer p.deinit(gpa);
    const cassette_path = try p.cassetteFile(gpa, "default.jsonl");
    defer gpa.free(cassette_path);

    var upstreams: std.ArrayList(proxy_mod.Upstream) = .empty;
    defer {
        for (upstreams.items) |u| gpa.free(u.base);
        upstreams.deinit(gpa);
    }
    for (providers) |prov| {
        const base = env.get(prov.override) orelse prov.default;
        try upstreams.append(gpa, .{
            .prefix = prov.prefix,
            .base = try gpa.dupe(u8, base),
        });
    }

    var proxy = try proxy_mod.Proxy.bind(
        gpa,
        io,
        cassette_path,
        if (strict) .strict else .record,
        upstreams.items,
        39000,
    );
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
    const line = std.fmt.bufPrint(
        &buf,
        "  {s} · {d} recorded · {d} replayed · {d} missed\n",
        .{ if (strict) "replaying" else "recording", stats.recorded, stats.replayed, stats.missed },
    ) catch "  done\n";
    printErr(io, line);

    std.process.exit(code);
}

fn printLine(io: Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(text) catch {};
    if (text.len == 0 or text[text.len - 1] != '\n') w.interface.writeAll("\n") catch {};
    w.interface.flush() catch {};
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
