# tapedeck

**Record your LLM calls once, replay them free.**

Point one environment variable at tapedeck and run your tests. The first run
records real API traffic to a cassette you commit. Every run after that is
instant, offline, and costs nothing.

```console
$ tapedeck -- pytest
  recording · 47 recorded · 0 replayed · 0 missed · 812443 tokens spent
  47 passed in 4m12s

$ git add .tapedeck && git commit -m 'test: add llm cassettes'

$ tapedeck --strict -- pytest
  replaying · 0 recorded · 47 replayed · 0 missed · 812443 tokens not spent
  47 passed in 1.8s
```

Your code is unmodified. tapedeck spawns your command with `ANTHROPIC_BASE_URL`,
`OPENAI_BASE_URL` and friends pointed at a loopback port, so **any language and
any SDK works** — Python, TypeScript, Go, Rust, Ruby, curl.

In CI, `--strict` turns an unmatched request into a failure instead of a silent
API call. No key in CI at all, which also means a PR from a fork can run your
full agent test suite.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/getsolmo/tapedeck/main/packaging/install.sh | sh
```

A single static binary, no runtime. Built in Zig with **zero dependencies** —
everything it needs is in the standard library.

## What you get

**In CI** — deterministic, offline, $0, no key.

**While developing** — stop paying to re-run the same prompt twenty times while
you debug the tool-call loop underneath it.

**When something breaks** — `tapedeck show` prints the whole conversation as the
model actually saw it, every turn and every tool call. Today you get that by
adding print statements.

## Commands

```sh
tapedeck -- <cmd>              # record on miss, replay on hit
tapedeck --strict -- <cmd>     # replay only; a miss fails the run
tapedeck --rerecord -- <cmd>   # refresh entries after a prompt change
tapedeck --cassette api -- <cmd>   # one cassette per suite
tapedeck ls                    # what is recorded, and what it cost
tapedeck show api              # the exchanges on a cassette
tapedeck key '{"model":"m"}'   # the match key for a request body
```

## Configuration

Optional `.tapedeck/config.json`. Without it, Anthropic, OpenAI and Gemini work
out of the box.

```json
{
  "providers": [
    { "name": "local", "base": "http://127.0.0.1:11434", "env": "OPENAI_BASE_URL" }
  ],
  "ignore": ["metadata.request_id", "trace_id"],
  "pricing": { "claude-opus-5": { "input": 15.0, "output": 75.0 } }
}
```

**`providers`** fronts anything with an HTTP API — Ollama, vLLM, OpenRouter, a
gateway of your own. `env` is the variable your SDK reads, declared rather than
guessed, because vendors disagree on the pattern.

**`ignore`** names JSON fields that change every run and must not affect
matching. Field paths rather than regex patterns: exact, and they cannot
silently over-match and collapse two different calls into one.

**`pricing`** is per million tokens.

```console
$ tapedeck ls
default              1 entries      1500 tokens       516 bytes  $0.0525
```

Token counts come from the provider's own response, so they are always right.
Dollars appear only for models you have priced — a built-in price table would go
stale silently, and a confidently wrong number is worse than none.

## Why not…

**vcrpy, nock, VCR?** They record HTTP, and they are excellent at it. LLM
traffic is streamed SSE, one logical call is six HTTP round-trips in a tool
loop, and the matching has to survive a date injected into a system prompt.
Also they are one library per language; tapedeck is one binary for all of them.

**LiteLLM?** It is a production gateway you adopt with a config file and Redis,
caching for cost. tapedeck makes git-committed fixtures with per-suite isolation
and fail-on-unmatched. Different job.

**promptfoo, deepeval?** They answer "is this output good?" tapedeck answers
"make the tests I already have fast and free." Complementary.

## Why an agent loop needs this specifically

Turn N+1's request embeds turn N's response, so a missed match re-records the
entire tail:

| per-turn miss rate | chance a 10-turn cassette replays end to end |
| --- | --- |
| 0.5% | 95.1% |
| 2% | 81.7% |
| 5% | 59.9% |
| 10% | 34.9% |

A 5% miss rate is respectable for a REST cassette library and useless here.
Matching is canonical JSON plus scrubbers for the things agents inject as a
matter of course — the current date, tool-call ids, absolute paths that differ
between a laptop and a CI runner — while never letting two different calls
collide. A wrong replay is a green test that proves nothing, so a miss is always
preferred to a guess. See `src/matching.zig`.

## Status

Working end to end for Anthropic, OpenAI, Gemini, and any provider you declare.
Verified against the real Anthropic API over TLS.

Not yet: conversation-scoped cassettes, per-request cost breakdown, real-time
SSE pacing.

## Building

```sh
zig build test --summary all   # 74 tests
zig build                      # zig-out/bin/tapedeck
```

Requires Zig 0.16.0 exactly — the version is pinned in `.zigversion` and in CI,
because Zig has no stable release and a minor bump reliably renames something in
`std`.

## License

MIT
