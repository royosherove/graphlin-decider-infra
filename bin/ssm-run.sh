#!/bin/bash
# Run one shell command on the Decider host through SSM Run Command. Print its output.
# The host comes from $DECIDER_STATE_DIR/decider-aws.env (default .state/decider-aws.env).
# bin/decider-aws writes that file. If the file does not exist, this script stops.
#
# Usage: bin/ssm-run.sh 'COMMAND' [TIMEOUT_SECONDS]      (default timeout: 600)
# Exit status: the exit status of COMMAND on the host, or 1 for an SSM error.
#
# Language: ASD-STE100.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR=${DECIDER_STATE_DIR:-$ROOT/.state}
ENV_FILE=$STATE_DIR/decider-aws.env
if [ ! -f "$ENV_FILE" ]; then
  echo "ssm-run.sh: no state file $ENV_FILE. Run: bin/decider-aws up" >&2
  exit 1
fi
# Read the values. Do not source the file (same as bin/decider-aws).
INSTANCE_ID=$(sed -n 's/^INSTANCE_ID=//p' "$ENV_FILE" 2> /dev/null | tail -n 1)
REGION=$(sed -n 's/^REGION=//p' "$ENV_FILE" 2> /dev/null | tail -n 1)
if [ -z "$INSTANCE_ID" ] || [ -z "$REGION" ]; then
  echo "ssm-run.sh: no INSTANCE_ID or REGION in $ENV_FILE" >&2
  exit 1
fi
echo "[ssm host=$INSTANCE_ID region=$REGION from $(basename "$ENV_FILE")]" >&2
COMMAND=$1
TIMEOUT=${2:-600}

params=$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": [sys.argv[2]]}))' \
  "$COMMAND" "$TIMEOUT")
id=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --parameters "$params" \
  --query Command.CommandId --output text) || exit 1

deadline=$((SECONDS + TIMEOUT + 60))
status=Pending
while [ $SECONDS -lt $deadline ]; do
  sleep 3
  status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2> /dev/null) || continue
  case "$status" in
    Pending | InProgress | Delayed) ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text
err=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text)
if [ -n "$err" ] && [ "$err" != "None" ]; then printf 'STDERR:\n%s\n' "$err" >&2; fi
code=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE_ID" \
  --query ResponseCode --output text)
echo "[ssm status=$status code=$code]" >&2
[ "$code" = "0" ]
