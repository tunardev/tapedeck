const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const sse = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":120,\"output_tokens\":1}}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":45}}\n\n";

fn hitCount(io: Io, gpa: std.mem.Allocator, path: []const u8) !usize {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch return 0;
    defer gpa.free(text);
    return std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

fn readPort(io: Io, gpa: std.mem.Allocator, path: []const u8) !u16 {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16)) catch return error.NotReady;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \n\r");
    if (trimmed.len == 0) return error.NotReady;
    return std.fmt.parseInt(u16, trimmed, 10) catch error.NotReady;
}

fn awaitStub(io: Io, gpa: std.mem.Allocator, port_file: []const u8) !u16 {
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (readPort(io, gpa, port_file)) |port| {
            const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", port);
            if (addr.connect(io, .{ .mode = .stream })) |sock| {
                sock.close(io);
                return port;
            } else |_| {}
        } else |_| {}
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.StubNeverStarted;
}

const fake_py =
    \\import http.server, sys, os
    \\H_ = {"n": 0}
    \\class H(http.server.BaseHTTPRequestHandler):
    \\    def do_POST(self):
    \\        self.rfile.read(int(self.headers.get("content-length", 0)))
    \\        H_["n"] += 1
    \\        open(os.environ["HITFILE"], "w").write(str(H_["n"]))
    \\        b = b'event: message_start\ndata: {"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":120,"output_tokens":1}}}\n\nevent: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":45}}\n\n'
    \\        self.send_response(200)
    \\        self.send_header("content-type", "text/event-stream")
    \\        self.send_header("content-length", str(len(b)))
    \\        self.end_headers()
    \\        self.wfile.write(b)
    \\    def log_message(self, *a): pass
    \\srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    \\open(os.environ["PORTFILE"], "w").write(str(srv.server_address[1]))
    \\srv.serve_forever()
;

test "record then replay through the installed binary" {
    const gpa = std.testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();
    const cwd = Io.Dir.cwd();

    const work = ".tapedeck-e2e";
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const py_path = work ++ "/fake.py";
    {
        const f = try cwd.createFile(io, py_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(fake_py);
        try w.interface.flush();
    }

    const hitfile = work ++ "/hits.txt";
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HITFILE", hitfile);
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");

    const port_file = work ++ "/port.txt";
    try env.put("PORTFILE", port_file);
    var fake = try std.process.spawn(io, .{
        .argv = &.{ "python3", py_path },
        .environ_map = &env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer fake.kill(io);

    const port = try awaitStub(io, gpa, port_file);

    const upstream = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(upstream);
    try env.put("TAPEDECK_HOME", work ++ "/.tapedeck");
    try env.put("TAPEDECK_ANTHROPIC_UPSTREAM", upstream);
    try env.put("ANTHROPIC_API_KEY", "sk-ant-supersecret");

    const client =
        \\curl -sS -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
        \\ -H "content-type: application/json" \
        \\ -H "x-api-key: $ANTHROPIC_API_KEY" \
        \\ -d "$PAYLOAD" -o "$OUT"
    ;

    try env.put("OUT", work ++ "/out1.txt");
    try env.put("PAYLOAD", "{\"model\":\"m\",\"messages\":[]}");
    const rec = try std.process.run(gpa, io, .{
        .argv = &.{ build_options.exe_path, "--", "sh", "-c", client },
        .environ_map = &env,
    });
    defer gpa.free(rec.stdout);
    defer gpa.free(rec.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, rec.term);
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));
    try std.testing.expect(std.mem.indexOf(u8, rec.stderr, "165 tokens spent") != null);

    try env.put("OUT", work ++ "/out2.txt");
    try env.put("PAYLOAD", "{\"messages\":[],\"model\":\"m\"}");
    const rep = try std.process.run(gpa, io, .{
        .argv = &.{ build_options.exe_path, "--strict", "--", "sh", "-c", client },
        .environ_map = &env,
    });
    defer gpa.free(rep.stdout);
    defer gpa.free(rep.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, rep.term);
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));
    try std.testing.expect(std.mem.indexOf(u8, rep.stderr, "165 tokens saved") != null);

    const a = try cwd.readFileAlloc(io, work ++ "/out1.txt", gpa, .limited(1 << 16));
    defer gpa.free(a);
    const b = try cwd.readFileAlloc(io, work ++ "/out2.txt", gpa, .limited(1 << 16));
    defer gpa.free(b);
    try std.testing.expectEqualStrings(sse, a);
    try std.testing.expectEqualStrings(a, b);

    const cassette = try cwd.readFileAlloc(io, work ++ "/.tapedeck/cassettes/default.jsonl", gpa, .limited(1 << 20));
    defer gpa.free(cassette);
    try std.testing.expect(std.mem.indexOf(u8, cassette, "supersecret") == null);
}

test "child exit code becomes the process exit code" {
    const gpa = std.testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TAPEDECK_HOME", ".tapedeck-e2e-code");
    defer Io.Dir.cwd().deleteTree(io, ".tapedeck-e2e-code") catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.exe_path, "--", "sh", "-c", "exit 7" },
        .environ_map = &env,
        .stderr = .ignore,
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try child.wait(io));
}

fn runCli(gpa: std.mem.Allocator, io: Io, home: []const u8, args: []const []const u8) ![]u8 {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TAPEDECK_HOME", home);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, build_options.exe_path);
    try argv.appendSlice(gpa, args);

    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env,
    });
    gpa.free(res.stderr);
    return res.stdout;
}

test "ls and show read a cassette written to disk" {
    const gpa = std.testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();
    const cwd = Io.Dir.cwd();

    const home = ".tapedeck-e2e-ls";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};
    try cwd.createDirPath(io, home ++ "/cassettes");

    const line =
        \\{"key":"k1","status":429,"headers":[{"name":"content-type","value":"application/json"}],"chunked":true,"encoding":"text","body":"slow down"}
    ;
    {
        const f = try cwd.createFile(io, home ++ "/cassettes/api.jsonl", .{ .truncate = true });
        defer f.close(io);
        var buf: [1024]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(line);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    const listed = try runCli(gpa, io, home, &.{"ls"});
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "1 entries") != null);

    const shown = try runCli(gpa, io, home, &.{ "show", "api" });
    defer gpa.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "status 429") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "streamed") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "slow down") != null);
}

test "a user declared provider works end to end" {
    const gpa = std.testing.allocator;
    var t: Io.Threaded = .init(gpa, .{});
    defer t.deinit();
    const io = t.io();
    const cwd = Io.Dir.cwd();

    const work = ".tapedeck-e2e-provider";
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const py_path = work ++ "/fake.py";
    {
        const f = try cwd.createFile(io, py_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(fake_py);
        try w.interface.flush();
    }

    const home = work ++ "/.tapedeck";
    try cwd.createDirPath(io, home);
    {
        const f = try cwd.createFile(io, home ++ "/config.json", .{ .truncate = true });
        defer f.close(io);
        var buf: [1024]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(
            \\{"providers":[{"name":"local","base":"http://unused","env":"MY_LLM_URL"}],
            \\ "ignore":["metadata.request_id"]}
        );
        try w.interface.flush();
    }

    const hitfile = work ++ "/hits.txt";
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HITFILE", hitfile);
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");

    const port_file = work ++ "/port.txt";
    try env.put("PORTFILE", port_file);
    var fake = try std.process.spawn(io, .{
        .argv = &.{ "python3", py_path },
        .environ_map = &env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer fake.kill(io);

    const port = try awaitStub(io, gpa, port_file);

    const upstream = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(upstream);
    try env.put("TAPEDECK_HOME", home);
    try env.put("TAPEDECK_LOCAL_UPSTREAM", upstream);
    try env.put("OUT", work ++ "/out.txt");

    const client =
        \\curl -sS -X POST "$MY_LLM_URL/v1/chat" -H 'content-type: application/json' \
        \\ -d "$PAYLOAD" -o "$OUT"
    ;
    try env.put("PAYLOAD", "{\"model\":\"m\",\"metadata\":{\"request_id\":\"first\"}}");
    const rec = try std.process.run(gpa, io, .{
        .argv = &.{ build_options.exe_path, "--", "sh", "-c", client },
        .environ_map = &env,
    });
    defer gpa.free(rec.stdout);
    defer gpa.free(rec.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, rec.term);
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));
    try std.testing.expect(std.mem.indexOf(u8, rec.stderr, "165 tokens spent") != null);

    try env.put("PAYLOAD", "{\"model\":\"m\",\"metadata\":{\"request_id\":\"second\"}}");
    var rep = try std.process.spawn(io, .{
        .argv = &.{ build_options.exe_path, "--strict", "--", "sh", "-c", client },
        .environ_map = &env,
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try rep.wait(io));
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));

    const replayed = try cwd.readFileAlloc(io, work ++ "/out.txt", gpa, .limited(1 << 16));
    defer gpa.free(replayed);
    try std.testing.expectEqualStrings(sse, replayed);
}
