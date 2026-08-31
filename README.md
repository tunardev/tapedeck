# tapedeck

**Record your LLM calls once, replay them free.**

Point one environment variable at tapedeck and run your tests. The first run
records real API traffic to a cassette you commit. Every run after that is
instant, offline, and costs nothing.

```console
$ tapedeck -- pytest
  recording      47 recorded    812,443 tokens spent
  47 passed in 4m12s

$ tapedeck --strict -- pytest
  replaying      47 replayed    812,443 tokens saved
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
curl -fsSL https://tapedeck.tunar.dev | sh
```

A single static binary, no runtime. Built in Zig with **zero dependencies** —
everything it needs is in the standard library.

## Before you commit a cassette

**A cassette is a test fixture, not a sanitised log.** It contains the request
that produced each response — your system prompt, whatever context your app
pulled in, tool results — and the model's full reply. tapedeck strips
credential *headers*, and nothing else.

Read one before you commit it:

```sh
tapedeck show default
```

If prompts must not enter your repository in plaintext, set `hash_keys` (below).
Response bodies are always stored verbatim; that is what a recording is.

## Commands

```sh
tapedeck -- <cmd>                # record on miss, replay on hit
tapedeck --strict -- <cmd>       # replay only; a miss fails the run
tapedeck --rerecord -- <cmd>     # refresh every entry the run touches
tapedeck --rerecord a1b2c3d4 -- <cmd>   # refresh one entry, replay the rest
tapedeck --cassette api -- <cmd> # one cassette per suite
tapedeck ls                      # what is recorded, and what it cost
tapedeck show api                # the exchanges, with ids, models and tokens
tapedeck key '{"model":"m"}'     # the match key for a request body
```

A prompt changed and one recorded answer is stale? `tapedeck show` gives you its
id, and `--rerecord <id>` re-buys that one call while the other forty-six
replay.

## Configuration

Optional `.tapedeck/config.json`. Without it, Anthropic, OpenAI and Gemini work
out of the box.

```json
{
  "providers": [
    { "name": "local", "base": "http://127.0.0.1:11434", "env": "OPENAI_BASE_URL" }
  ],
  "ignore": ["metadata.request_id", "trace_id"],
  "pricing": { "claude-opus-4": { "input": 15.0, "output": 75.0 } },
  "hash_keys": false
}
```

**`providers`** fronts anything with an HTTP API — Ollama, vLLM, OpenRouter, a
gateway of your own. `env` is the variable your SDK reads, declared rather than
guessed, because vendors disagree on the pattern.

**`ignore`** names JSON fields that change every run and must not affect
matching. Field paths rather than regex patterns: exact, and they cannot
silently over-match and collapse two different calls into one.

**`pricing`** is per million tokens, matched by longest prefix so
`claude-opus-4` covers `claude-opus-4-20250514`. A `+` after a total means some
entries had no configured price.

**`hash_keys`** stores a hash of the request instead of the request. Matching is
unaffected; you lose readable diffs and gain a cassette with no prompt in it.

```console
$ tapedeck ls
default              2 entries       3,000 tokens  $0.1050
```

Token counts come from the provider's own response, so they are always right.
Dollars appear only for models you have priced — a built-in price table would go
stale silently, and a confidently wrong number is worse than none.

## Why not…

**vcrpy, nock, VCR?** They record HTTP, and they are excellent at it. LLM
traffic is streamed SSE, one logical call is six HTTP round-trips in a tool
loop, and matching has to survive a date injected into a system prompt. They are
also one library per language; tapedeck is one binary for all of them.

**LiteLLM?** A production gateway you adopt with a config file and Redis,
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

Matching is a length-prefixed encoding of the method, provider, path and
canonicalised body, so no byte inside a value can be mistaken for structure.
Scrubbers handle what agents inject as a matter of course — the current date,
tool-call ids, home directories that differ between a laptop and a CI runner —
while staying narrow enough that `main.zig` and `build.zig` remain distinct
requests, and `gpt-4o-2024-08-06` stays distinct from `gpt-4o-2024-11-20`.

A wrong replay is a green test that proves nothing, so a miss is always
preferred to a guess. See `src/matching.zig`.

## Status

Working end to end for Anthropic, OpenAI, Gemini, and any provider you declare.
Verified against the real Anthropic API over TLS.

Not yet: conversation-scoped cassettes, per-request cost breakdown, real-time
SSE pacing.

## Building

```sh
zig build test --summary all
zig build
```

Requires Zig 0.16.0 exactly — pinned in `.zigversion` and in CI, because Zig has
no stable release and a minor bump reliably renames something in `std`. The test
suite needs `python3` and `curl` for its end-to-end cases.

## License

MIT
