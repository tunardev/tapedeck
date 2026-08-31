# tapedeck

**record your LLM calls once, replay them free**

Point one environment variable at tapedeck and run your tests. The first run
records real API traffic to a cassette you commit. Every run after that is
instant, offline, and costs nothing.

```console
$ tapedeck -- pytest
  recording · 47 calls · 812k tokens · $2.80 · 4m 12s

$ git add .tapedeck && git commit -m 'test: add llm cassettes'

$ tapedeck -- pytest
  replaying · 47/47 matched · $0.00 · 1.8s
```

Your code is unmodified. tapedeck spawns your test command with
`OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` pointed at a loopback port, so any
language and any SDK works — Python, TypeScript, Go, Rust, Ruby, curl.

In CI, `--strict` turns an unmatched request into a failure instead of a silent
API call. No key in CI at all.

## Why not a general HTTP cassette library

Agent loops compound. Turn N+1's request embeds turn N's response, so one
missed match re-records the entire tail:

| per-turn miss rate | chance a 10-turn cassette replays end to end |
| --- | --- |
| 0.5% | 95.1% |
| 2% | 81.7% |
| 5% | 59.9% |
| 10% | 34.9% |

A 5% miss rate is respectable for a REST cassette library and useless here.
Matching has to survive the things agents inject into prompts as a matter of
course — the current date, tool-call ids, absolute paths that differ between a
laptop and a CI runner — without ever letting two different calls collide.
See `src/matching.zig`.

## Status

Early. Matching, cassette storage, and redaction are implemented and tested;
the proxy is in progress.

Built in Zig 0.16 with **zero dependencies** — everything it needs is in the
standard library, so `zig build` is the whole toolchain story and release
binaries cross-compile for every target from one machine.

## License

MIT
