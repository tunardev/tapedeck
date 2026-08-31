#!/bin/sh
# Verifies the TLS path to a real provider. Not part of `zig build test`:
# it needs the network, and CI has neither network policy nor a key for this.
#
# No credential is required. An unauthenticated request returns a 401 JSON
# error over TLS, which is enough to prove the handshake, the response parse,
# and the record path all work against the genuine endpoint.
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

zig build --build-file "$root/build.zig" >/dev/null
bin="$root/zig-out/bin/tapedeck"

TAPEDECK_HOME="$work/.tapedeck" \
  "$bin" -- sh -c "curl -sS -o '$work/body.txt' -w '%{http_code}' -X POST \
    \"\$ANTHROPIC_BASE_URL/v1/messages\" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d '{\"model\":\"claude-opus-5\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' \
    > '$work/code.txt'"

code=$(cat "$work/code.txt")
echo "status: $code"
echo "body:   $(head -c 200 "$work/body.txt")"

if [ "$code" != "401" ]; then
  echo "FAIL: expected 401 from an unauthenticated request, got $code" >&2
  exit 1
fi

if ! grep -q authentication_error "$work/body.txt"; then
  echo "FAIL: response body is not an anthropic error envelope" >&2
  exit 1
fi

cassette="$work/.tapedeck/cassettes/default.jsonl"
[ -f "$cassette" ] || { echo "FAIL: nothing was recorded" >&2; exit 1; }
grep -q '"status":401' "$cassette" || { echo "FAIL: 401 not recorded" >&2; exit 1; }

echo "PASS: TLS handshake, response parse, and record all work against the real API"
