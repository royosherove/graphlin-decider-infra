#!/bin/bash
# Offline test: bin/ssm-run.sh reads the host only from decider-aws.env, and stops with a
# clear message when no state file exists.
# Language: ASD-STE100.
#
# This test uses a stub aws in a temporary directory. It makes no network call. The IDs are
# example IDs from the AWS documentation. It checks:
#   1. No state file: ssm-run.sh stops with a clear message and exit 1.
#   2. Only an instance.env file exists (no decider-aws.env): ssm-run.sh does NOT use it. It
#      stops with the clear message and exit 1.
#   3. decider-aws.env exists: ssm-run.sh reads that host and runs the command. It prints the
#      host output and exits with the host response code.
# Usage: tests/test-ssm-run.sh
#   TEST_BASH=/path/to/bash   the bash that runs bin/ssm-run.sh (default /bin/bash)
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_BASH=${TEST_BASH:-/bin/bash}
SSM=$ROOT/bin/ssm-run.sh
mkdir -p "$ROOT/.state"
WORK=$(mktemp -d "$ROOT/.state/test-ssm-run.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/aws" << 'EOF'
#!/bin/bash
# Stub aws for ssm-run.sh. The host output is a fixed marker. No network call.
all="$*"
case "${1:-} ${2:-}" in
  "ssm send-command") echo "cmd-stub-0001" ;;
  "ssm get-command-invocation")
    case "$all" in
      *Status*) echo Success ;;
      *StandardOutputContent*) echo "HELLO-FROM-HOST" ;;
      *StandardErrorContent*) echo None ;;
      *ResponseCode*) echo 0 ;;
      *) echo None ;;
    esac ;;
  *) echo "stub aws: unexpected call: $all" >&2; exit 254 ;;
esac
exit 0
EOF
chmod +x "$STUB/aws"

# 1. No state file.
STATE="$WORK/empty"
mkdir -p "$STATE"
OUT=$(PATH="$STUB:$PATH" DECIDER_STATE_DIR="$STATE" "$TEST_BASH" "$SSM" 'echo hi' 2>&1)
CODE=$?
case "$CODE:$OUT" in
  1:*"no state file"*"decider-aws.env"*) pass "1 no state file: clear message and exit 1" ;;
  *) fail "1 no state file: exit $CODE, out: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac

# 2. Only an instance.env file.
STATE="$WORK/instance"
mkdir -p "$STATE"
printf 'INSTANCE_ID=i-0abcdef1234567890\nREGION=us-west-2\n' > "$STATE/instance.env"
OUT=$(PATH="$STUB:$PATH" DECIDER_STATE_DIR="$STATE" "$TEST_BASH" "$SSM" 'echo hi' 2>&1)
CODE=$?
case "$CODE:$OUT" in
  1:*"no state file"*) pass "2 instance.env is not used: clear message and exit 1" ;;
  *) fail "2 ssm-run.sh used instance.env (exit $CODE): $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac

# 3. decider-aws.env exists: the command runs on that host.
STATE="$WORK/good"
mkdir -p "$STATE"
printf 'INSTANCE_ID=i-1234567890abcdef0\nREGION=us-west-2\nMARKET=on-demand\n' > "$STATE/decider-aws.env"
OUT=$(PATH="$STUB:$PATH" DECIDER_STATE_DIR="$STATE" "$TEST_BASH" "$SSM" 'echo hi' 2> "$WORK/err3")
CODE=$?
ERR=$(cat "$WORK/err3")
if [ "$CODE" -eq 0 ] && [ "$OUT" = "HELLO-FROM-HOST" ]; then
  pass "3 decider-aws.env: the command runs and exit 0"
else
  fail "3 decider-aws.env run (exit $CODE): out '$OUT'"
fi
case "$ERR" in
  *"host=i-1234567890abcdef0"*"from decider-aws.env"*) pass "3b the host comes from decider-aws.env" ;;
  *) fail "3b no 'from decider-aws.env' host line: $(printf '%s' "$ERR" | tr '\n' ' ')" ;;
esac

if [ $FAILS -eq 0 ]; then echo "test-ssm-run: all checks pass"; exit 0; fi
echo "test-ssm-run: $FAILS checks failed"
exit 1
