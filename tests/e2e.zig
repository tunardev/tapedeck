//! End-to-end: the real binary, a fake provider, and a child process.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const fake_port = 38897;
const sse = "event: a\ndata: {\"t\":1}\n\n";

fn hitCount(io: Io, gpa: std.mem.Allocator, path: []const u8) !usize {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch return 0;
    defer gpa.free(text);
    return std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

/// A provider stub in python, so the test exercises the shipped binary rather
/// than linking the proxy into the test process.
const fake_py =
    \\import http.server, sys, os
    \\H_ = {"n": 0}
    \\class H(http.server.BaseHTTPRequestHandler):
    \\    def do_POST(self):
    \\        self.rfile.read(int(self.headers.get("content-length", 0)))
    \\        H_["n"] += 1
    \\        open(os.environ["HITFILE"], "w").write(str(H_["n"]))
    \\        b = b'event: a\ndata: {"t":1}\n\n'
    \\        self.send_response(200)
    \\        self.send_header("content-type", "text/event-stream")
    \\        self.send_header("content-length", str(len(b)))
    \\        self.end_headers()
    \\        self.wfile.write(b)
    \\    def log_message(self, *a): pass
    \\http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
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

    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake_port});
    var fake = try std.process.spawn(io, .{
        .argv = &.{ "python3", py_path, port_str },
        .environ_map = &env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // kill reaps the child; waiting again would assert on a cleared pid
    defer fake.kill(io);

    // The stub needs a moment to bind before the first request.
    var waited: usize = 0;
    while (waited < 50) : (waited += 1) {
        const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", fake_port);
        if (addr.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
            break;
        } else |_| {}
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    const upstream = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake_port});
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

    // Record.
    try env.put("OUT", work ++ "/out1.txt");
    try env.put("PAYLOAD", "{\"model\":\"m\",\"messages\":[]}");
    var rec = try std.process.spawn(io, .{
        .argv = &.{ build_options.exe_path, "--", "sh", "-c", client },
        .environ_map = &env,
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try rec.wait(io));
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));

    // Replay: same logical call, drifted key order, strict so it cannot call out.
    try env.put("OUT", work ++ "/out2.txt");
    try env.put("PAYLOAD", "{\"messages\":[],\"model\":\"m\"}");
    var rep = try std.process.spawn(io, .{
        .argv = &.{ build_options.exe_path, "--strict", "--", "sh", "-c", client },
        .environ_map = &env,
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try rep.wait(io));
    try std.testing.expectEqual(@as(usize, 1), try hitCount(io, gpa, hitfile));

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
