#!/bin/bash
# Offline test for "tunnel stop" and kill_plugins in bin/decider-aws. Language: ASD-STE100.
#
# Risk: a stop with "pkill -f session-manager-plugin.*ID" also matches the command line of the
# calling shell, so "tunnel stop" can stop that shell. kill_plugins stops only the recorded PIDs.
#
# The test uses a stub aws and a stub session-manager-plugin in a temporary directory. It makes
# no network call. It uses port 18998, not the default port 8099. The instance ID is an example
# ID from the AWS documentation. It checks:
#   1. The tunnel process writes the PIDs of aws and of the plugin to the children file.
#   2. "tunnel status" shows the plugin PID.
#   3. "tunnel stop" does not stop the calling shell. The command line of that shell has the
#      plugin name and the instance ID.
#   4. "tunnel stop" does not stop a different process with the plugin name and the instance ID
#      in its command line.
#   5. "tunnel stop" stops the tunnel process, the aws process and the plugin process.
#
# Usage: tests/test-tunnel-stop.sh
#   TEST_BASH=/path/to/bash   the bash that runs bin/decider-aws (default /bin/bash)
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_BASH=${TEST_BASH:-/bin/bash}
DECIDER=$ROOT/bin/decider-aws
ID=i-1234567890abcdef0
PORT=18998
mkdir -p "$ROOT/.state"
WORK=$(mktemp -d "$ROOT/.state/test-tunnel-stop.XXXXXX") || exit 1
STATE=$WORK/state
STUB=$WORK/stub
mkdir -p "$STATE" "$STUB"
FAILS=0
TUN="" AWS="" PLUGIN="" BYSTANDER=""

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
alive() { [ -n "$1" ] && kill -0 "$1" 2> /dev/null; }

# Children of one PID (one level). ps -A -o and awk work on macOS and Linux.
children() { ps -A -o pid= -o ppid= | awk -v p="$1" '$2 == p { print $1 }'; }

# Stop the processes of this test only. The test knows their PIDs. No pkill.
# shellcheck disable=SC2329 # The EXIT trap calls it.
cleanup() {
  local pid
  for pid in $PLUGIN $AWS $TUN $BYSTANDER; do
    alive "$pid" && kill "$pid" 2> /dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$STUB/aws" << 'EOF'
#!/bin/bash
# Stub aws: "ssm start-session" runs the stub plugin as a child, as the AWS CLI v2 does.
case "${1:-} ${2:-}" in
  "ssm start-session")
    target=""
    while [ $# -gt 0 ]; do
      [ "$1" = --target ] && target=$2
      shift
    done
    "$(dirname "$0")/session-manager-plugin" '{"SessionId":"stub"}' us-west-2 StartSession '' \
      "{\"Target\":\"$target\"}" https://ssm.us-west-2.amazonaws.com
    ;;
  *) echo "stub aws: unexpected call: $*" >&2; exit 254 ;;
esac
EOF
cat > "$STUB/session-manager-plugin" << 'EOF'
#!/bin/bash
# Stub session-manager-plugin: stay alive until a signal comes.
trap 'exit 0' TERM INT HUP
while :; do
  sleep 1 &
  wait $!
done
EOF
chmod +x "$STUB/aws" "$STUB/session-manager-plugin"
printf 'INSTANCE_ID=%s\nREGION=us-west-2\nMARKET=on-demand\n' "$ID" > "$STATE/decider-aws.env"

export PATH="$STUB:$PATH" DECIDER_STATE_DIR="$STATE" DECIDER_LOCAL_PORT=$PORT
[ "$(command -v aws)" = "$STUB/aws" ] || { echo "FAIL the stub aws is not first on PATH"; exit 1; }

# The same start as "tunnel start" does, without the /health wait (the stub has no listener).
"$TEST_BASH" "$DECIDER" _tunnel-run > "$WORK/tunnel.log" 2>&1 < /dev/null &
TUN=$!
echo "$TUN" > "$STATE/decider-aws-tunnel.pid"

# The child of one PID that has PATTERN (a case pattern) in its command line.
child_with() { # PID PATTERN
  local pid
  for pid in $(children "$1"); do
    # shellcheck disable=SC2254
    case "$(ps -o args= -p "$pid" 2> /dev/null)" in $2) echo "$pid"; return 0 ;; esac
  done
  return 1
}

# Find the stub aws (child of the tunnel process) and the stub plugin (child of aws). The tunnel
# process also has short-lived children (command substitutions). Thus select aws by its command
# line, and look again when the selected PID is not alive.
for _ in $(seq 1 50); do
  alive "$AWS" || AWS=$(child_with "$TUN" '*start-session*')
  [ -n "$AWS" ] && PLUGIN=$(child_with "$AWS" '*session-manager-plugin*')
  [ -n "$PLUGIN" ] && break
  sleep 0.2
done
if [ -z "$PLUGIN" ]; then
  echo "FAIL the stub plugin did not start. Tunnel log:"
  cat "$WORK/tunnel.log"
  exit 1
fi

# A different process. Its command line has the plugin name and the instance ID.
bash -c 'while :; do sleep 1; done' "bystander session-manager-plugin $ID" &
BYSTANDER=$!

# 1. The children file.
for _ in $(seq 1 25); do
  grep -q "^$PLUGIN plugin$" "$STATE/decider-aws-tunnel.children" 2> /dev/null && break
  sleep 0.2
done
if grep -q "^$AWS aws$" "$STATE/decider-aws-tunnel.children" 2> /dev/null \
  && grep -q "^$PLUGIN plugin$" "$STATE/decider-aws-tunnel.children"; then
  pass "1 the children file has aws $AWS and plugin $PLUGIN"
else
  fail "1 the children file has no aws $AWS or no plugin $PLUGIN: $(cat "$STATE/decider-aws-tunnel.children" 2> /dev/null | tr '\n' ' ')"
fi

# 2. tunnel status.
status=$("$TEST_BASH" "$DECIDER" tunnel status 2>&1)
case "$status" in
  *"plugin processes: "*"$PLUGIN(plugin)"*) pass "2 tunnel status shows the plugin $PLUGIN" ;;
  *) fail "2 tunnel status does not show the plugin $PLUGIN: $(printf '%s' "$status" | tr '\n' ' ')" ;;
esac

# 3. The calling shell. Its command line ($0) has the plugin name and the instance ID.
caller=$(bash -c '"$1" "$2" tunnel stop > "$3" 2>&1; echo "caller alive rc=$?"' \
  "caller session-manager-plugin $ID" "$TEST_BASH" "$DECIDER" "$WORK/stop.log")
case "$caller" in
  "caller alive rc=0") pass "3 the calling shell is alive and tunnel stop exits 0" ;;
  *) fail "3 the calling shell stopped or tunnel stop failed: '$caller'. Log: $(tr '\n' ' ' < "$WORK/stop.log")" ;;
esac

# 4. The other process.
if alive "$BYSTANDER"; then pass "4 the other process is alive"; else fail "4 tunnel stop stopped the other process"; fi

# 5. The processes of the tunnel.
sleep 1
left=""
for pid in $TUN $AWS $PLUGIN; do alive "$pid" && left="$left $pid"; done
if [ -z "$left" ]; then
  pass "5 the tunnel process, aws and the plugin are stopped"
else
  fail "5 these tunnel processes are alive:$left"
fi

if [ $FAILS -eq 0 ]; then echo "test-tunnel-stop: all checks pass"; exit 0; fi
echo "test-tunnel-stop: $FAILS checks failed"
exit 1
