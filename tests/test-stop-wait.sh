#!/bin/bash
# Offline test: cmd_stop in bin/decider-aws waits up to 20 min for the stop, and gives a
# clear message when the stop takes longer. Language: ASD-STE100.
#
# The AWS CLI waiter "aws ec2 wait instance-stopped" stops after 10 min (40 checks, 15 s
# apart). The stop of a GPU host can take many minutes. Thus cmd_stop polls up to
# DECIDER_STOP_WAIT_SECONDS (default 1200 = 20 min). On a longer stop it names the host and
# says that the stop continues in AWS.
#
# This test uses a stub aws. It makes no network call. The instance ID is an example ID from
# the AWS documentation. DECIDER_STOP_POLL_SECONDS=0 keeps the test fast. It checks:
#   1. The host reaches "stopped": exit 0, and the log says "Wait up to 20 min." (the default).
#   2. The host is "stopping" first, then "stopped": the waiter keeps polling and exits 0.
#   3. The host stays "stopping" past the wait: exit non-zero, the message names the host and
#      says the stop continues in AWS.
# Usage: tests/test-stop-wait.sh
#   TEST_BASH=/path/to/bash   the bash that runs bin/decider-aws (default /bin/bash)
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_BASH=${TEST_BASH:-/bin/bash}
DECIDER=$ROOT/bin/decider-aws
ID=i-1234567890abcdef0
mkdir -p "$ROOT/.state"
WORK=$(mktemp -d "$ROOT/.state/test-stop-wait.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

STUB="$WORK/stub"
STATE="$WORK/state"
mkdir -p "$STUB" "$STATE"
printf 'INSTANCE_ID=%s\nREGION=us-west-2\nMARKET=on-demand\n' "$ID" > "$STATE/decider-aws.env"

# Stub aws. STUB_MODE controls the reported instance state:
#   stopped   -> always "stopped"
#   stopping  -> always "stopping"
#   transient -> "stopping" once (counter file), then "stopped"
cat > "$STUB/aws" << 'EOF'
#!/bin/bash
all="$*"
case "${1:-} ${2:-}" in
  "scheduler delete-schedule") ;;
  "ec2 stop-instances") ;;
  "ec2 describe-instances")
    case "${STUB_MODE:-stopped}" in
      stopped) echo stopped ;;
      stopping) echo stopping ;;
      transient)
        n=0; [ -f "$STUB_COUNT" ] && n=$(cat "$STUB_COUNT")
        n=$((n + 1)); echo "$n" > "$STUB_COUNT"
        if [ "$n" -ge 2 ]; then echo stopped; else echo stopping; fi ;;
    esac ;;
  *) ;;
esac
exit 0
EOF
chmod +x "$STUB/aws"

run_stop() { # MODE [WAIT_SECONDS]
  local mode=$1 wait=${2:-}
  : > "$WORK/count"
  OUT=$(env PATH="$STUB:$PATH" DECIDER_STATE_DIR="$STATE" DECIDER_STOP_POLL_SECONDS=0 \
    STUB_MODE="$mode" STUB_COUNT="$WORK/count" ${wait:+DECIDER_STOP_WAIT_SECONDS=$wait} \
    "$TEST_BASH" "$DECIDER" stop 2>&1)
  CODE=$?
}

# 1. Immediate stop. No DECIDER_STOP_WAIT_SECONDS: the default 20 min must show in the log.
run_stop stopped
if [ "$CODE" -eq 0 ]; then pass "1 immediate stop exits 0"; else fail "1 immediate stop exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ')"; fi
case "$OUT" in
  *"Wait up to 20 min."*) pass "1b the default wait is 20 min" ;;
  *) fail "1b no 'Wait up to 20 min.' line: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac
case "$OUT" in *"stopped"*) pass "1c the log says stopped" ;; *) fail "1c no 'stopped' in the log" ;; esac

# 2. Transient "stopping" then "stopped".
run_stop transient 60
if [ "$CODE" -eq 0 ]; then pass "2 transient stop exits 0 after polling"; else fail "2 transient stop exit $CODE: $(printf '%s' "$OUT" | tr '\n' ' ')"; fi

# 3. Timeout: the host stays "stopping", the wait is 0.
run_stop stopping 0
if [ "$CODE" -ne 0 ]; then pass "3 timeout exits non-zero ($CODE)"; else fail "3 timeout did not fail"; fi
case "$OUT" in
  *"$ID"*"continues in AWS"*) pass "3b the message names the host and says the stop continues" ;;
  *) fail "3b timeout message is not clear: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac

if [ $FAILS -eq 0 ]; then echo "test-stop-wait: all checks pass"; exit 0; fi
echo "test-stop-wait: $FAILS checks failed"
exit 1
