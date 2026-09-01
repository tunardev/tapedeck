# tapedeck

**Record your LLM calls once. Replay them for free.**

Run your tests through tapedeck. The first run saves every API call to a file.
Every run after that reads from that file. No network, no cost, same answers.

```console
$ tapedeck -- pytest
  recording      47 recorded    812,443 tokens spent
  47 passed in 4m12s

$ tapedeck --strict -- pytest
  replaying      47 replayed    812,443 tokens saved
  47 passed in 1.8s
```

You don't change your code. tapedeck starts your command with
`ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` pointing at a local port, so it works
with any language and any SDK — Python, TypeScript, Go, Rust, Ruby, curl.

Use `--strict` in CI. A call that was never recorded fails the run instead of
quietly costing money. You don't need an API key in CI at all.

## Install

```sh
curl -fsSL https://tapedeck.tunar.dev | sh
```

One small binary. Nothing to install alongside it.

## Read a cassette before you commit it

A cassette holds the real request and the real answer. That means your prompts,
anything your app put in them, and what the model said back. tapedeck removes
API keys from headers. It does not remove anything else.

Look at one first:

```sh
tapedeck show default
```

If prompts should not go in your repo, turn on `hash_keys` below.

## Commands

```sh
tapedeck -- <cmd>                      # record what is missing, replay the rest
tapedeck --strict -- <cmd>             # replay only, fail on anything missing
tapedeck --rerecord -- <cmd>           # refresh everything this run touches
tapedeck --rerecord a1b2c3d4 -- <cmd>  # refresh one call, replay the rest
tapedeck --cassette api -- <cmd>       # separate file per test suite
tapedeck --realtime --strict -- <cmd>  # replay a stream at its recorded speed
tapedeck ls                            # what is saved, and what it cost
tapedeck show api                      # the calls, with ids, models and tokens
tapedeck key '{"model":"m"}'           # how a request body gets matched
```

Changed a prompt and one saved answer is now wrong? `tapedeck show` gives you
its id. `--rerecord <id>` buys that one call again. The rest still replay.

## Settings

Add `.tapedeck/config.json` if you need it. Anthropic, OpenAI and Gemini work
without any config.

```json
{
  "providers": [
    { "name": "local", "base": "http://127.0.0.1:11434", "env": "OPENAI_BASE_URL" }
  ],
  "ignore": ["metadata.request_id", "trace_id"],
  "pricing": { "claude-opus-5": { "input": 15.0, "output": 75.0 } },
  "hash_keys": false
}
```

**providers** — point tapedeck at anything with an HTTP API: Ollama, vLLM,
OpenRouter, your own gateway. `env` is the variable your SDK reads. You write it
out because every vendor picks a different name.

**ignore** — fields that change on every run and should not affect matching.
These are field names, not patterns. A pattern can match too much and make two
different calls look the same.

**pricing** — dollars per million tokens. A short name covers its dated
snapshots: `claude-haiku-4-5` also prices `claude-haiku-4-5-20251001`. A `+` on
the total means some calls had no price set.

**hash_keys** — save a hash of the request instead of the request. Matching
still works. You lose readable diffs and gain a file with no prompts in it.

```console
$ tapedeck ls
default              2 entries        3,000 tokens  $0.1050

$ tapedeck show
15762a56  status 200  claude-opus-5  1000 in / 500 out  $0.0525
```

Token counts come from the provider, so they are always right. Prices only show
for models you set a price for. A built-in price list would go out of date
quietly, and a wrong number is worse than no number.

## How is this different from…

**vcrpy, nock, VCR** — they record HTTP and they do it well. But LLM traffic is
streamed, one call is often six HTTP requests in a tool loop, and matching has
to survive a date stuck into your prompt. They are also one library per
language. tapedeck is one binary for all of them.

**LiteLLM** — a gateway you run in production with a config file and Redis, to
cut cost. tapedeck makes test files you commit to git. Different job.

**promptfoo, deepeval** — they answer "is this answer good?" tapedeck answers
"make my tests fast and free." They work together fine.

## Why agent loops need this

In an agent loop, each request contains the answer to the last one. So one bad
match ruins every call after it:

| calls that miss | chance a 10-step run replays fully |
| --- | --- |
| 0.5% | 95% |
| 2% | 82% |
| 5% | 60% |
| 10% | 35% |

5% is fine for a normal HTTP cassette library. Here it is useless.

tapedeck builds its match key from the method, the provider, the path and the
body, with a length written before every value so no text inside a value can be
mistaken for structure. It also cleans up things agents add on their own: the
current date, tool call ids, and home directory paths that differ between your
laptop and CI.

## What works

Anthropic, OpenAI, Gemini, and any provider you add yourself. Tested against the
real Anthropic API over TLS.

Replay is instant by default. Add `--realtime` if you need a stream to arrive at
the speed it was recorded, for code that reacts to tokens as they come in.

## License

MIT. See [LICENSE](LICENSE).
