#!/usr/bin/env bash
# Starts a checkout's built server on a throwaway home and checks each fork feature
# that a running server shows. Stops the server by its own PID.
#   smoke.sh <checkout> <expected-version, e.g. 0.1.8+monitor>
set -euo pipefail

dir=$(cd "${1:?usage: smoke.sh <checkout> <version>}" && pwd)
want=${2:?usage: smoke.sh <checkout> <version>}
bin="$dir/apps/server/dist/bin.mjs"
[ -f "$bin" ] || { echo "no build at $bin" >&2; exit 1; }

nodev=$(sed -n 's/.*"node": *"\([0-9.]*\)".*/\1/p' "$dir/package.json" | head -1)
[ -x "$HOME/.nvm/versions/node/v$nodev/bin/node" ] && PATH="$HOME/.nvm/versions/node/v$nodev/bin:$PATH"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null
[ "$(node --version)" = "v$nodev" ] || echo "warn: node $(node --version), package.json wants $nodev"

home=$(mktemp -d)
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
T3CODE_ENVIRONMENT_LABEL=fork-smoke node "$bin" serve --base-dir "$home" --port "$port" --no-browser "$home" >"$home/server.log" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  rm -rf "$home"
}
trap cleanup EXIT

base="http://127.0.0.1:$port"
for _ in $(seq 60); do curl -sf "$base/.well-known/t3/environment" >"$home/env.json" 2>/dev/null && break; sleep 0.5; done
[ -s "$home/env.json" ] || { echo "server did not start:"; tail -20 "$home/server.log"; exit 1; }

fails=0
check() { if [ "$2" = ok ]; then echo "PASS  $1"; else echo "FAIL  $1: $2"; fails=$((fails + 1)); fi; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$@"; }

got=$(field "$home/env.json" serverVersion)
check "version" "$([ "$got" = "$want" ] && echo ok || echo "got $got")"
echo "info  databaseMigration $(field "$home/env.json" databaseMigration)"
got=$(field "$home/env.json" label)
check "environment-label" "$([ "$got" = fork-smoke ] && echo ok || echo "label $got")"

node "$bin" auth mcp-token --base-dir "$home" --json >"$home/token.json" 2>"$home/token.err" || true
token=$(field "$home/token.json" token 2>/dev/null || true)
check "mcp-token" "$([ -n "$token" ] && echo ok || head -c 300 "$home/token.err")"

pair=$(node "$bin" pair --base-dir "$home" --base-url "$base" 2>&1 || true)
check "pair-base-url" "$(grep -q "Pairing URL: $base/pair" <<<"$pair" && echo ok || echo "no pairing URL on $base")"

if [ -n "$token" ]; then
  h=(-H "Authorization: Bearer $token" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
  curl -s -D "$home/mcp.hdr" "${h[@]}" "$base/mcp" -o /dev/null \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fork-smoke","version":"1"}}}'
  sid=$(sed -n 's/^mcp-session-id: *//Ip' "$home/mcp.hdr" | tr -d '\r')
  curl -s "${h[@]}" -H "mcp-session-id: $sid" "$base/mcp" -o /dev/null -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s "${h[@]}" -H "mcp-session-id: $sid" "$base/mcp" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >"$home/tools.txt"
  missing=$(python3 - "$home/tools.txt" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read()
data = [l[5:] for l in raw.splitlines() if l.startswith("data:")]
tools = json.loads(data[0] if data else raw)["result"]["tools"]
schema = json.dumps(next(t for t in tools if t["name"] == "t3_thread_list").get("outputSchema", {}))
print(" ".join(f for f in ["branch", "worktreePath", "lastVisitedAt", "latestRunCompletedAt",
                           "pendingRequest", "hasActionableProposedPlan"] if f'"{f}"' not in schema))
EOF
  )
  check "list-worktree + list-unread" "$([ -z "$missing" ] && echo ok || echo "t3_thread_list lacks $missing")"
fi
echo "launch-branch has no runtime check; ThreadLaunchService.test.ts covers it"
exit "$fails"
