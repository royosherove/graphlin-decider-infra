#!/bin/bash
# Offline test: tags of the one-time spot request. Language: ASD-STE100.
#
# EC2 refuses an on-demand launch with InvalidParameterValue when the request or the launch
# template has a tag specification for spot-instances-request. Then the fallback stops.
#
# This test runs "bin/decider-aws up" with the stub AWS CLI in tests/stub/aws. It checks:
#   1. Spot has no capacity. up continues to on-demand, and the on-demand launch starts.
#   2. The on-demand request and the launch template have no spot-instances-request tags.
#   3. The spot request is one-time and has the tags Project and ManagedBy.
#   4. Spot has capacity. up starts a spot host, and the spot request has the tags.
# It makes no network call. Usage: tests/test-launch-tags.sh
#   TEST_BASH=/path/to/bash   the bash that runs bin/decider-aws (default /bin/bash)
set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/.state"
WORK=$(mktemp -d "$ROOT/.state/test-launch-tags.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# Run "up" in a clean state directory with the stub first on PATH.
# Usage: run_up NAME SPOT_MODE. Sets OUT, CODE, CALLS and STATE.
run_up() {
  local name=$1 spot=$2
  STATE="$WORK/$name"
  mkdir -p "$STATE/stub"
  CALLS="$STATE/stub/calls.log"
  : > "$CALLS"
  OUT=$(PATH="$ROOT/tests/stub:$PATH" STUB_AWS_LOG="$CALLS" STUB_AWS_DIR="$STATE/stub" STUB_SPOT="$spot" \
    DECIDER_STATE_DIR="$STATE" DECIDER_TYPES=g6.xlarge DECIDER_REGIONS=us-west-2 \
    DECIDER_MARKETS="spot on-demand" DECIDER_GLOBAL_REGION=us-west-2 \
    "${TEST_BASH:-/bin/bash}" "$ROOT/bin/decider-aws" up 2>&1)
  CODE=$?
}

# The run-instances calls of one market.
spot_calls() { grep '^ec2 run-instances' "$CALLS" | grep '"MarketType":"spot"'; }
demand_calls() { grep '^ec2 run-instances' "$CALLS" | grep -v '"MarketType":"spot"'; }

# 0 when a text has a spot-instances-request tag specification with both project tags.
has_spot_request_tags() {
  case "$1" in
    *ResourceType=spot-instances-request,Tags=*Key=Project,Value=graphlin-decider*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *ResourceType=spot-instances-request,Tags=*Key=ManagedBy,Value=decider-aws*) return 0 ;;
    *) return 1 ;;
  esac
}

template_has_spot_request_tags() {
  grep -Eq 'ResourceType:[[:space:]]*spot-instances-request' "$STATE/stub/regional.yaml"
}

echo "== case 1: no spot capacity, fallback to on-demand"
run_up fallback capacity
if [ $CODE -eq 0 ] && grep -q '^MARKET=on-demand$' "$STATE/decider-aws.env" 2> /dev/null \
  && grep -q '^INSTANCE_ID=i-1234567890abcdef0$' "$STATE/decider-aws.env"; then
  pass "up falls back to on-demand and starts i-1234567890abcdef0"
else
  fail "up did not start the on-demand host (exit $CODE): $(printf '%s' "$OUT" | grep -E 'ERROR|fatal' | head -n 3 | tr '\n' ' ')"
fi
DEMAND=$(demand_calls)
if [ -z "$DEMAND" ]; then
  fail "no on-demand run-instances call"
else
  case "$DEMAND" in
    *spot-instances-request*) fail "the on-demand request has a spot-instances-request tag specification" ;;
    *) pass "the on-demand request has no spot-instances-request tag specification" ;;
  esac
fi
if [ -f "$STATE/stub/regional.yaml" ]; then
  if template_has_spot_request_tags; then
    fail "the launch template has a spot-instances-request tag specification (on-demand gets it too)"
  else
    pass "the launch template has no spot-instances-request tag specification"
  fi
else
  fail "the regional template was not deployed"
fi
SPOT=$(spot_calls)
case "$SPOT" in
  *'"SpotInstanceType":"one-time"'*) pass "the spot request is one-time" ;;
  *) fail "the spot request is not one-time: $SPOT" ;;
esac
case "$SPOT" in
  *persistent*) fail "the spot request is persistent" ;;
esac
if has_spot_request_tags "$SPOT"; then
  pass "the spot request has the tags Project and ManagedBy"
else
  fail "the spot request has no spot-instances-request tags with Project and ManagedBy"
fi

echo "== case 2: spot capacity"
run_up spot ok
if [ $CODE -eq 0 ] && grep -q '^MARKET=spot$' "$STATE/decider-aws.env" 2> /dev/null; then
  pass "up starts a spot host"
else
  fail "up did not start a spot host (exit $CODE): $(printf '%s' "$OUT" | grep -E 'ERROR|fatal' | head -n 3 | tr '\n' ' ')"
fi
if [ -n "$(demand_calls)" ]; then fail "up tried on-demand after a spot success"; fi
if has_spot_request_tags "$(spot_calls)"; then
  pass "the spot request has the tags Project and ManagedBy"
else
  fail "the spot request has no spot-instances-request tags with Project and ManagedBy"
fi

if [ $FAILS -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi
echo "RESULT: FAIL ($FAILS checks)"
exit 1
