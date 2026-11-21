#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="${HEXO_BIN:-$ROOT/hexo}"
PORT=$((21000 + ($$ % 20000)))
OUT="$(mktemp -d)"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$OUT"
}
trap cleanup EXIT

(cd "$ROOT" && HEXO_TEST_PORT="$PORT" "$BIN" "$ROOT/examples/hexoweb_routes.hexo") >"$OUT/server.log" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 60); do
  if curl --silent --show-error --fail "http://127.0.0.1:$PORT/users/health" -o "$OUT/health" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then cat "$OUT/server.log" >&2; echo "hexoweb server did not start" >&2; exit 1; fi
# First request above is a readiness request, so the server accepts one more than the checks.

curl --silent --show-error --fail "http://127.0.0.1:$PORT/users/42?q=hello%20world" >"$OUT/user"
grep -q '"id":"42"' "$OUT/user"
grep -q '"search":"hello world"' "$OUT/user"

curl --silent --show-error --fail -X POST --data 'name=Ada&skill=Hexo' "http://127.0.0.1:$PORT/echo" >"$OUT/form"
grep -q '"name":"Ada"' "$OUT/form"

curl --silent --show-error --fail -X POST -H 'Content-Type: application/json' --data '{"ok":true,"n":7}' "http://127.0.0.1:$PORT/api" >"$OUT/json"
grep -q '"ok":true' "$OUT/json"

curl --silent --show-error -D "$OUT/redirect.headers" -o /dev/null "http://127.0.0.1:$PORT/go"
grep -q '^HTTP/1.1 303' "$OUT/redirect.headers"
grep -qi '^Location: /users/redirected' "$OUT/redirect.headers"

curl --silent --show-error --fail "http://127.0.0.1:$PORT/assets/test.txt" >"$OUT/static"
grep -q 'hexo static file OK' "$OUT/static"

curl --silent --show-error --fail -X PUT --data 'put-data' "http://127.0.0.1:$PORT/resource" >"$OUT/put"
grep -q '"method":"PUT"' "$OUT/put"
grep -q '"body":"put-data"' "$OUT/put"

curl --silent --show-error --fail -X PATCH --data 'patch-data' "http://127.0.0.1:$PORT/resource" >"$OUT/patch"
grep -q '"method":"PATCH"' "$OUT/patch"

curl --silent --show-error --fail -X DELETE "http://127.0.0.1:$PORT/resource" >"$OUT/delete"
grep -q '"method":"DELETE"' "$OUT/delete"

code=$(curl --silent --show-error -o "$OUT/method-not-allowed" -w '%{http_code}' "http://127.0.0.1:$PORT/resource")
test "$code" = "405"

code=$(curl --silent --show-error -X OPTIONS -D "$OUT/options.headers" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/resource")
test "$code" = "204"
grep -qi '^Allow:.*PUT' "$OUT/options.headers"

grep -q 'Allow:' "$OUT/options.headers"

curl --silent --show-error --head "http://127.0.0.1:$PORT/users/42" -D "$OUT/head.headers" -o /dev/null
grep -q '^HTTP/1.1 200' "$OUT/head.headers"

curl --silent --show-error --fail "http://127.0.0.1:$PORT/page" >"$OUT/page"
grep -q '<title>&lt;Hexo &amp; Web&gt;</title>' "$OUT/page"
grep -q '<h1>Hexo site</h1>' "$OUT/page"

curl --silent --show-error --fail -H 'Cookie: sid=session-123' -H 'X-Test: hexo' "http://127.0.0.1:$PORT/info" >"$OUT/info"
grep -q '"session":"session-123"' "$OUT/info"
grep -q '"custom":"hexo"' "$OUT/info"

wait "$PID"
PID=""
echo "Hexoweb HTTP integration tests (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/HTML/cookies): PASS"
