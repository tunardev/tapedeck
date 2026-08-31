# AGENTS.md

tapedeck — "record your LLM calls once, replay them free." A local proxy that
records LLM API traffic to cassettes and replays them for tests. Single Zig
module under `src/`, **pinned to Zig 0.16.0** (`.zigversion`, and the CI job).

## Verify before you claim done

```sh
zig build test --summary all   # --summary all matters: the test step is silent on success
zig fmt --check src build.zig
```

`zig build test` prints nothing when it passes, so a broken test *step* and a
passing one look identical without `--summary all`. Always read the count.

There is also a `Makefile` (`make test`, `make check`).

## Zig 0.16 specifics

0.16 landed the `Io` overhaul; anything written for 0.15 or earlier is wrong.
Notably: I/O functions take an `io: Io` parameter, `std.net` is `std.Io.net`,
`GeneralPurposeAllocator` is `DebugAllocator`, `ArrayList` is unmanaged by
default (methods take `gpa`), and `main` takes `std.process.Init`, which is
where the allocator, `Io`, args, and environment come from.

Read `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` as primary documentation.
Blog posts and older answers will not compile.

## Modules

| Module | Role |
|---|---|
| `src/main.zig` | Binary `tapedeck`. Argument parsing; owns no logic. |
| `src/root.zig` | Module root; re-exports everything below. |
| `src/matching.zig` | Canonical JSON and scrubbers; turns a request body into a cassette key. |
| `src/cassette.zig` | On-disk format, lossless body encoding, atomic save. |
| `src/paths.zig` | Cassette directory resolution. |
| `src/redact.zig` | Credential header classification. |

## The invariant that governs matching

Two runs of the same test must produce the same key. Two different calls must
never produce the same key. The second is the one that matters: a missed match
costs an API call, a wrong match is a green test that proves nothing.

Byte-exact matching fails the first. Order-based matching ("replay the Nth
request") fails the second and must never be an option. Canonical JSON plus
scrubbers is the only strategy that holds both.

Because turn N+1 of an agent loop embeds turn N's response, per-turn miss rate
compounds geometrically — a 5% per-turn miss means 40% of ten-turn cassettes
re-record. Treat any regression in match stability as a correctness bug.

`std.json` preserves document order, so the key sort in `writeCanonical` is
load-bearing. Deleting it must fail a test; if it ever stops doing so, the
test is decorative.

## Cassettes

Cassettes are committed to the repository under test, so the default location
is project-relative (`./.tapedeck`), not under the user's home.
`TAPEDECK_HOME` overrides it and is how tests get an isolated directory.

Never write an API key into a cassette. Bodies are stored as text when valid
UTF-8 and base64 otherwise — never read a captured body as a string, or one
invalid byte discards the whole response.
