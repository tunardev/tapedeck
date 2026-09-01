const std = @import("std");
const Io = std.Io;
const tapedeck = @import("tapedeck");

const cassette_mod = tapedeck.cassette;
const config_mod = tapedeck.config;
const matching = tapedeck.matching;
const paths_mod = tapedeck.paths;
const proxy_mod = tapedeck.proxy;
const runner = tapedeck.runner;
const Paths = paths_mod.Paths;

const exit_tapedeck_error: u8 = 120;
const exit_interrupted: u8 = 130;
const exit_usage: u8 = 121;

var interrupted: std.atomic.Value(bool) = .init(false);

fn onInterrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .seq_cst);
}

fn catchInterrupts() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onInterrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

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
    \\  --rerecord [id]     refresh every entry the run touches, or just one
    \\  --cassette <name>   cassette to use (default: $TAPEDECK_CASSETTE or "default")
    \\
;

pub fn main(init: std.process.Init) !void {
    run(init) catch |e| {
        printErr(init.io, "tapedeck: ");
        printErr(init.io, @errorName(e));
        printErr(init.io, "\n");
        std.process.exit(exit_tapedeck_error);
    };
}

const Command = union(enum) {
    wrap: []const []const u8,
    ls,
    show,
    where,
    key: []const u8,
    version,
    help,
};

const Invocation = struct {
    command: Command,
    mode: proxy_mod.Mode = .record,
    rerecord_id: ?[]const u8 = null,
    cassette: []const u8 = "default",
};

fn optionValue(args: []const []const u8, i: *usize) ?[]const u8 {
    i.* += 1;
    if (i.* >= args.len) return null;
    const v = args[i.*];
    if (v.len > 0 and v[0] == '-') return null;
    return v;
}

fn parse(args: []const []const u8, env_cassette: ?[]const u8) !Invocation {
    var inv: Invocation = .{ .command = .help };
    if (env_cassette) |name| {
        if (name.len > 0) inv.cassette = name;
    }
    var mode_set = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            inv.command = .{ .wrap = args[i + 1 ..] };
            return inv;
        } else if (std.mem.eql(u8, a, "--strict")) {
            if (mode_set) return error.ConflictingModes;
            inv.mode = .strict;
            mode_set = true;
        } else if (std.mem.eql(u8, a, "--rerecord")) {
            if (mode_set) return error.ConflictingModes;
            inv.mode = .rerecord;
            mode_set = true;
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-' and
                !std.mem.eql(u8, args[i + 1], "--"))
            {
                i += 1;
                inv.rerecord_id = args[i];
            }
        } else if (std.mem.eql(u8, a, "--cassette")) {
            inv.cassette = optionValue(args, &i) orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, a, "--version")) {
            inv.command = .version;
            return inv;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            inv.command = .help;
            return inv;
        } else if (std.mem.eql(u8, a, "where")) {
            inv.command = .where;
            return inv;
        } else if (std.mem.eql(u8, a, "ls")) {
            inv.command = .ls;
            return inv;
        } else if (std.mem.eql(u8, a, "show")) {
            if (optionValue(args, &i)) |name| inv.cassette = name;
            inv.command = .show;
            return inv;
        } else if (std.mem.eql(u8, a, "key")) {
            inv.command = .{ .key = optionValue(args, &i) orelse return error.MissingOptionValue };
            return inv;
        } else {
            return error.UnknownArgument;
        }
    }
    return inv;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| try argv.append(gpa, a);

    const inv = parse(argv.items, env.get("TAPEDECK_CASSETTE")) catch |e| {
        printErr(io, switch (e) {
            error.ConflictingModes => "tapedeck: --strict and --rerecord cannot be combined\n",
            error.MissingOptionValue => "tapedeck: an option is missing its value\n",
            else => usage,
        });
        std.process.exit(exit_usage);
    };

    const home = try Paths.resolve(gpa, env);
    defer home.deinit(gpa);
    var cfg = config_mod.Config.load(gpa, io, home.root) catch |e| switch (e) {
        error.MalformedConfig => {
            printErr(io, "tapedeck: config.json is not valid tapedeck config\n");
            std.process.exit(exit_tapedeck_error);
        },
        else => return e,
    };
    defer cfg.deinit();

    switch (inv.command) {
        .version => printLine(io, "tapedeck 0.1.0"),
        .help => printLine(io, usage),
        .where => {
            const dir = try home.cassetteFile(gpa, "");
            defer gpa.free(dir);
            printLine(io, dir);
        },
        .key => |body| {
            const k = try matching.key(gpa, .{}, body, .{ .ignore = cfg.ignore });
            defer gpa.free(k);
            printLine(io, k);
        },
        .ls => try list(gpa, io, home, cfg),
        .show => try show(gpa, io, home, inv.cassette),
        .wrap => |command| try wrap(gpa, io, env, home, cfg, inv, command),
    }
}

fn cassettePath(gpa: std.mem.Allocator, home: Paths, name: []const u8) ![]u8 {
    const safe = paths_mod.sanitizeName(name) orelse return error.UnsafeCassetteName;
    const file = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{safe});
    defer gpa.free(file);
    return home.cassetteFile(gpa, file);
}

fn wrap(
    gpa: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    home: Paths,
    cfg: config_mod.Config,
    inv: Invocation,
    command: []const []const u8,
) !void {
    if (command.len == 0) {
        printErr(io, "tapedeck: nothing to run; try `tapedeck -- pytest`\n");
        std.process.exit(exit_usage);
    }

    const path = try cassettePath(gpa, home, inv.cassette);
    defer gpa.free(path);

    if (inv.rerecord_id) |id| try requireEntry(gpa, io, path, id);

    var upstreams: std.ArrayList(proxy_mod.Upstream) = .empty;
    defer {
        for (upstreams.items) |u| gpa.free(u.base);
        upstreams.deinit(gpa);
    }
    for (cfg.providers) |prov| {
        const upper = try std.ascii.allocUpperString(gpa, prov.name);
        defer gpa.free(upper);
        const var_name = try std.fmt.allocPrint(gpa, "TAPEDECK_{s}_UPSTREAM", .{upper});
        defer gpa.free(var_name);
        try upstreams.append(gpa, .{
            .prefix = prov.name,
            .base = try gpa.dupe(u8, env.get(var_name) orelse prov.base),
            .env = prov.env,
        });
    }

    var proxy = try proxy_mod.Proxy.bind(gpa, io, path, inv.mode, upstreams.items, 39000);
    proxy.ignore = cfg.ignore;
    proxy.hash_keys = cfg.hash_keys;
    proxy.rerecord_id = inv.rerecord_id;
    defer proxy.deinit();

    const injected = try proxy.baseUrls(gpa);
    defer {
        for (injected) |v| {
            gpa.free(v[0]);
            gpa.free(v[1]);
        }
        gpa.free(injected);
    }

    catchInterrupts();

    const serving = try std.Thread.spawn(.{}, proxy_mod.Proxy.serve, .{&proxy});
    const result = runner.run(io, command, env, injected);

    proxy.shutdown();
    serving.join();
    proxy.flush() catch |e| {
        printErr(io, "tapedeck: could not write the cassette: ");
        printErr(io, @errorName(e));
        printErr(io, "\n");
        std.process.exit(exit_tapedeck_error);
    };

    try report(gpa, io, inv.mode, proxy.snapshot());

    const code = try result;
    std.process.exit(if (interrupted.load(.seq_cst) and code == 0) exit_interrupted else code);
}

fn requireEntry(gpa: std.mem.Allocator, io: Io, path: []const u8, id: []const u8) !void {
    var c = try cassette_mod.Cassette.load(gpa, io, path);
    defer c.deinit();
    for (c.values()) |e| {
        if (std.mem.eql(u8, &cassette_mod.shortId(e.key), id)) return;
    }
    printErr(io, "tapedeck: no cassette entry with id ");
    printErr(io, id);
    printErr(io, "\n");
    std.process.exit(exit_usage);
}

fn report(gpa: std.mem.Allocator, io: Io, mode: proxy_mod.Mode, s: proxy_mod.Stats) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const verb = switch (mode) {
        .record => "recording",
        .strict => "replaying",
        .rerecord => "re-recording",
    };
    try out.print(gpa, "  {s: <12}", .{verb});
    if (s.recorded > 0) try printField(gpa, &out, s.recorded, "recorded");
    if (s.replayed > 0) try printField(gpa, &out, s.replayed, "replayed");
    if (s.recorded == 0 and s.replayed == 0) try printField(gpa, &out, 0, "calls");
    if (s.missed > 0) try printField(gpa, &out, s.missed, "missed");
    if (s.failed > 0) try printField(gpa, &out, s.failed, "failed");

    const spent = s.spent_input + s.spent_output;
    const saved = s.saved_input + s.saved_output;
    if (spent > 0) {
        try out.appendSlice(gpa, "  ");
        try printGrouped(gpa, &out, spent);
        try out.appendSlice(gpa, " tokens spent");
    } else if (saved > 0) {
        try out.appendSlice(gpa, "  ");
        try printGrouped(gpa, &out, saved);
        try out.appendSlice(gpa, " tokens saved");
    }
    try out.append(gpa, '\n');
    printErr(io, out.items);
}

fn printField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: usize, label: []const u8) !void {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    try printGrouped(gpa, &digits, n);
    try out.print(gpa, "{s: >6} {s: <9}", .{ digits.items, label });
}

fn printGrouped(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: u64) !void {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try out.append(gpa, ',');
        try out.append(gpa, c);
    }
}

fn list(gpa: std.mem.Allocator, io: Io, home: Paths, cfg: config_mod.Config) !void {
    const dir_path = try home.cassetteFile(gpa, "");
    defer gpa.free(dir_path);

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return printLine(io, "no cassettes recorded yet"),
        else => return e,
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var found: usize = 0;

    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        found += 1;
        const name = entry.name[0 .. entry.name.len - ".jsonl".len];
        const full = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(full);

        var c = cassette_mod.Cassette.load(gpa, io, full) catch {
            try out.print(gpa, "{s: <20}  unreadable\n", .{name});
            continue;
        };
        defer c.deinit();

        var tokens: u64 = 0;
        var dollars: f64 = 0;
        var unpriced: usize = 0;
        for (c.values()) |e| {
            tokens += e.input_tokens + e.output_tokens;
            if (cfg.cost(e.model, e.input_tokens, e.output_tokens)) |d| {
                dollars += d;
            } else if (e.input_tokens + e.output_tokens > 0) {
                unpriced += 1;
            }
        }

        var grouped: std.ArrayList(u8) = .empty;
        defer grouped.deinit(gpa);
        try printGrouped(gpa, &grouped, tokens);
        try out.print(gpa, "{s: <20} {d: >5} entries {s: >12} tokens", .{
            name, c.count(), grouped.items,
        });
        if (dollars > 0) {
            try out.print(gpa, "  ${d:.4}{s}", .{ dollars, if (unpriced > 0) "+" else "" });
        }
        try out.append(gpa, '\n');
    }

    if (found == 0) return printLine(io, "no cassettes recorded yet");
    printRaw(io, out.items);
}

fn show(gpa: std.mem.Allocator, io: Io, home: Paths, name: []const u8) !void {
    const path = try cassettePath(gpa, home, name);
    defer gpa.free(path);

    var c = cassette_mod.Cassette.load(gpa, io, path) catch |e| switch (e) {
        error.CorruptCassette => {
            printErr(io, "tapedeck: cassette is corrupt\n");
            std.process.exit(exit_tapedeck_error);
        },
        else => return e,
    };
    defer c.deinit();

    if (c.count() == 0) return printLine(io, "cassette is empty");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (c.values()) |e| {
        try out.print(gpa, "{s}  status {d}", .{ cassette_mod.shortId(e.key), e.status });
        if (e.chunked) try out.appendSlice(gpa, "  streamed");
        if (e.model.len > 0) try out.print(gpa, "  {s}", .{e.model});
        if (e.input_tokens + e.output_tokens > 0) {
            try out.print(gpa, "  {d} in / {d} out", .{ e.input_tokens, e.output_tokens });
        }
        try out.append(gpa, '\n');
        for (e.headers) |h| try out.print(gpa, "  {s}: {s}\n", .{ h.name, h.value });
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

const testing = std.testing;

test "a flag is never taken as an option value" {
    try testing.expectError(error.MissingOptionValue, parse(&.{ "--cassette", "--strict", "--", "x" }, null));
}

test "conflicting mode flags are rejected" {
    try testing.expectError(error.ConflictingModes, parse(&.{ "--strict", "--rerecord", "--", "x" }, null));
    try testing.expectError(error.ConflictingModes, parse(&.{ "--rerecord", "--strict", "--", "x" }, null));
}

test "everything after the separator belongs to the child" {
    const inv = try parse(&.{ "--strict", "--", "pytest", "--strict", "-k", "x" }, null);
    try testing.expectEqual(proxy_mod.Mode.strict, inv.mode);
    try testing.expectEqual(@as(usize, 4), inv.command.wrap.len);
    try testing.expectEqualStrings("pytest", inv.command.wrap[0]);
}

test "rerecord takes an optional selector" {
    const all = try parse(&.{ "--rerecord", "--", "pytest" }, null);
    try testing.expect(all.rerecord_id == null);

    const one = try parse(&.{ "--rerecord", "a1b2c3d4", "--", "pytest" }, null);
    try testing.expectEqualStrings("a1b2c3d4", one.rerecord_id.?);
    try testing.expectEqualStrings("pytest", one.command.wrap[0]);
}

test "an empty cassette environment variable means unset" {
    const inv = try parse(&.{ "--", "x" }, "");
    try testing.expectEqualStrings("default", inv.cassette);

    const named = try parse(&.{ "--", "x" }, "api");
    try testing.expectEqualStrings("api", named.cassette);
}

test "the cassette flag overrides the environment" {
    const inv = try parse(&.{ "--cassette", "flagged", "--", "x" }, "from-env");
    try testing.expectEqualStrings("flagged", inv.cassette);
}

test "an unknown argument is an error" {
    try testing.expectError(error.UnknownArgument, parse(&.{"--nope"}, null));
}

test "counts are grouped for reading" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try printGrouped(testing.allocator, &out, 812443);
    try testing.expectEqualStrings("812,443", out.items);

    out.clearRetainingCapacity();
    try printGrouped(testing.allocator, &out, 0);
    try testing.expectEqualStrings("0", out.items);

    out.clearRetainingCapacity();
    try printGrouped(testing.allocator, &out, 1000);
    try testing.expectEqualStrings("1,000", out.items);
}
