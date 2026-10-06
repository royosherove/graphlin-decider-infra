#!/bin/bash
# Offline test for "tunnel start", "tunnel status" and "status" in bin/decider-aws.
# Language: ASD-STE100.
#
# Risk: a different local process answers GET /health on the tunnel port. Then "tunnel start"
# must not write "the tunnel is already open". It must stop with an error.
#
# The test uses a stub aws in a temporary directory. The stub refuses all calls. Thus the test
# makes no AWS call and no network call. A python3 HTTP server is the local process that
# answers /health. It listens on 127.0.0.1, on a free port that the operating system selects.
# bin/decider-aws does not use python3. The instance ID is an example ID from the AWS
# documentation. It checks:
#   1. A different process answers /health, and no tunnel is recorded. "tunnel start" stops
#      with the error, the lsof command and a non-zero exit.
#   2. The same process: "tunnel status" does not show health "ok". It exits non-zero.
#   3. The same process: "status" does not show health "ok".
#   4. A recorded tunnel: the tunnel process is alive, and the children file has the listener
#      PID. "tunnel start" writes "the tunnel is already open" and exits 0.
#   5. The recorded tunnel of check 4, but lsof finds no listener PID. "tunnel start" does not
#      write "already open". It stops with an error and a non-zero exit.
#   6. The health servers are alive after the checks: the tool stopped no process.
#   7. The recorded tunnel of check 4, but no lsof on PATH. "tunnel start" does not write
#      "open". It stops with an error and a non-zero exit.
#
# Usage: tests/test-tunnel-start.sh
#   TEST_BASH=/path/to/bash   the bash that runs bin/decider-aws (default /bin/bash)
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_BASH=${TEST_BASH:-/bin/bash}
DECIDER=$ROOT/bin/decider-aws
ID=i-1234567890abcdef0
mkdir -p "$ROOT/.state"
WORK=$(mktemp -d "$ROOT/.state/test-tunnel-start.XXXXXX") || exit 1
STUB=$WORK/stub
NOLSOF=$WORK/nolsof
STATE_A=$WORK/state-a
STATE_B=$WORK/state-b
mkdir -p "$STUB" "$NOLSOF" "$STATE_A" "$STATE_B"
FAILS=0
OTHER="" LISTENER="" TUN=""

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
alive() { [ -n "$1" ] && kill -0 "$1" 2> /dev/null; }
oneline() { printf '%s' "$1" | tr '\n' ' '; }

# Stop the processes of this test only. The test knows their PIDs. No pkill.
# shellcheck disable=SC2329 # The EXIT trap calls it.
cleanup() {
  local pid
  for pid in $OTHER $LISTENER $TUN; do
    if alive "$pid"; then
      kill "$pid" 2> /dev/null
      wait "$pid" 2> /dev/null
    fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$STUB/aws" << 'EOF'
#!/bin/bash
# Stub aws: this test expects no AWS call.
echo "stub aws: unexpected call: $*" >&2
exit 254
EOF
# Stub lsof for check 5: it finds no listener.
cat > "$NOLSOF/lsof" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB/aws" "$NOLSOF/lsof"

# The local process that answers GET /health with HTTP 200. It writes its port to the file $1.
cat > "$WORK/health-server.py" << 'EOF'
import http.server
import os
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"status": "ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1] + ".tmp", "w") as out:
    out.write(str(server.server_address[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
server.serve_forever()
EOF

# Wait until a health server writes its port file. Print the port.
wait_port() { # FILE
  for _ in $(seq 1 50); do
    if [ -s "$1" ]; then cat "$1"; return 0; fi
    sleep 0.2
  done
  return 1
}

for s in "$STATE_A" "$STATE_B"; do
  printf 'INSTANCE_ID=%s\nREGION=us-west-2\nMARKET=on-demand\n' "$ID" > "$s/decider-aws.env"
done
export PATH="$STUB:$PATH"
[ "$(command -v aws)" = "$STUB/aws" ] || { echo "FAIL the stub aws is not first on PATH"; exit 1; }

# A different process: a health server that no tunnel record has.
python3 "$WORK/health-server.py" "$WORK/port-a" &
OTHER=$!
PORT_A=$(wait_port "$WORK/port-a") || { echo "FAIL the first health server did not start"; exit 1; }

# 1. tunnel start, with a different process on the port and no recorded tunnel.
OUT=$(DECIDER_STATE_DIR="$STATE_A" DECIDER_LOCAL_PORT=$PORT_A "$TEST_BASH" "$DECIDER" tunnel start 2>&1)
CODE=$?
case "$CODE:$OUT" in
  0:* | *"already open"*)
    fail "1 tunnel start accepted a different process on port $PORT_A (exit $CODE): $(oneline "$OUT")" ;;
  *"a different process uses port $PORT_A"*"lsof -nP -iTCP:$PORT_A -sTCP:LISTEN"*)
    pass "1 a different process on the port: tunnel start stops with the error and exit $CODE" ;;
  *) fail "1 tunnel start gives no clear error (exit $CODE): $(oneline "$OUT")" ;;
esac

# 2. tunnel status, with the same process on the port.
OUT=$(DECIDER_STATE_DIR="$STATE_A" DECIDER_LOCAL_PORT=$PORT_A "$TEST_BASH" "$DECIDER" tunnel status 2>&1)
CODE=$?
case "$CODE:$OUT" in
  0:* | *"health through the tunnel: ok"*)
    fail "2 tunnel status accepted a different process on port $PORT_A (exit $CODE): $(oneline "$OUT")" ;;
  *"a different process uses the port"*"lsof -nP -iTCP:$PORT_A -sTCP:LISTEN"*)
    pass "2 a different process on the port: tunnel status shows it and exit $CODE" ;;
  *) fail "2 tunnel status gives no clear message (exit $CODE): $(oneline "$OUT")" ;;
esac

# 3. status, with the same process on the port. The stub aws refuses the EC2 and Scheduler calls.
OUT=$(DECIDER_STATE_DIR="$STATE_A" DECIDER_LOCAL_PORT=$PORT_A "$TEST_BASH" "$DECIDER" status 2>&1)
case "$OUT" in
  *"health through the tunnel: ok"*)
    fail "3 status accepted a different process on port $PORT_A: $(oneline "$OUT")" ;;
  *"a different process uses the port"*) pass "3 a different process on the port: status shows it" ;;
  *) fail "3 status gives no clear message: $(oneline "$OUT")" ;;
esac

# A recorded tunnel: a sleep process is the tunnel process, and a second health server is the
# listener. The children file has the listener PID.
python3 "$WORK/health-server.py" "$WORK/port-b" &
LISTENER=$!
PORT_B=$(wait_port "$WORK/port-b") || { echo "FAIL the second health server did not start"; exit 1; }
sleep 300 &
TUN=$!
echo "$TUN" > "$STATE_B/decider-aws-tunnel.pid"
printf '%s plugin\n' "$LISTENER" > "$STATE_B/decider-aws-tunnel.children"

# 4. tunnel start, with the recorded tunnel.
OUT=$(DECIDER_STATE_DIR="$STATE_B" DECIDER_LOCAL_PORT=$PORT_B "$TEST_BASH" "$DECIDER" tunnel start 2>&1)
CODE=$?
case "$CODE:$OUT" in
  0:*"the tunnel is already open"*) pass "4 a recorded tunnel: tunnel start writes already open and exit 0" ;;
  *) fail "4 tunnel start did not accept the recorded tunnel (exit $CODE): $(oneline "$OUT")" ;;
esac

# 5. tunnel start, with the recorded tunnel, but lsof finds no listener.
OUT=$(PATH="$NOLSOF:$PATH" DECIDER_STATE_DIR="$STATE_B" DECIDER_LOCAL_PORT=$PORT_B \
  "$TEST_BASH" "$DECIDER" tunnel start 2>&1)
CODE=$?
case "$CODE:$OUT" in
  0:* | *"already open"*)
    fail "5 lsof finds no listener, but tunnel start accepted the port (exit $CODE): $(oneline "$OUT")" ;;
  *"ERROR"*"port $PORT_B"*) pass "5 lsof finds no listener: tunnel start stops with an error and exit $CODE" ;;
  *) fail "5 tunnel start gives no clear error (exit $CODE): $(oneline "$OUT")" ;;
esac

if alive "$OTHER" && alive "$LISTENER"; then
  pass "6 the health servers are alive: tunnel start and tunnel status stopped no process"
else
  fail "6 a health server stopped"
fi

# 7. tunnel start, with the recorded tunnel, but no lsof on PATH. The directory $NOPATH has a
# link to each command on PATH, but not to lsof.
NOPATH=$WORK/nopath
mkdir -p "$NOPATH"
for dir in $(printf '%s' "$PATH" | tr ':' ' '); do
  for cmd in "$dir"/*; do
    name=${cmd##*/}
    [ "$name" = lsof ] && continue
    [ -x "$cmd" ] && [ ! -e "$NOPATH/$name" ] && ln -s "$cmd" "$NOPATH/$name"
  done
done
OUT=$(PATH="$NOPATH" DECIDER_STATE_DIR="$STATE_B" DECIDER_LOCAL_PORT=$PORT_B "$TEST_BASH" "$DECIDER" tunnel start 2>&1)
CODE=$?
case "$CODE:$OUT" in
  0:* | *"open"*) fail "7 no lsof on PATH, but tunnel start did not stop (exit $CODE): $(oneline "$OUT")" ;;
  *"ERROR"*"lsof is not on PATH"*) pass "7 no lsof on PATH: tunnel start stops with an error and exit $CODE" ;;
  *) fail "7 tunnel start gives no clear error (exit $CODE): $(oneline "$OUT")" ;;
esac

if [ $FAILS -eq 0 ]; then echo "test-tunnel-start: all checks pass"; exit 0; fi
echo "test-tunnel-start: $FAILS checks failed"
exit 1
