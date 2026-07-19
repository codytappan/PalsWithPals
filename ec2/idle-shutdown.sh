#!/usr/bin/env bash
# Idle watcher: runs every 5 minutes from cron.
#
# On each run it:
#   1. discovers this instance's ID from IMDSv2,
#   2. counts players via the container's REST CLI,
#   3. caches the count to a local file AND an SSM Parameter (so the Lambda
#      /palworld-status can answer instantly),
#   4. after EMPTY_LIMIT consecutive empty checks, saves the world and stops
#      this instance.
set -euo pipefail

source /opt/palworld/idle.env  # AWS_REGION, PLAYER_COUNT_PARAM_NAME, EMPTY_LIMIT

COUNTER_FILE=/opt/palworld/empty_count
COUNT_FILE=/opt/palworld/player_count

# IMDSv2 token + instance id.
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# Count players. rest-cli players prints one line per player after a header;
# fall back to 0 if the call fails (e.g. server still booting).
if PLAYERS_RAW=$(docker exec palworld-server rest-cli players 2>/dev/null); then
  COUNT=$(echo "$PLAYERS_RAW" | grep -c . || true)
  # Subtract a header line if present.
  [ "$COUNT" -gt 0 ] && COUNT=$((COUNT - 1))
else
  COUNT=0
fi

# Cache the count locally and in SSM.
echo "$COUNT" > "$COUNT_FILE"
aws ssm put-parameter --region "$AWS_REGION" \
  --name "$PLAYER_COUNT_PARAM_NAME" --type String \
  --value "$COUNT" --overwrite >/dev/null 2>&1 || true

# Track consecutive empty checks.
EMPTY=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
if [ "$COUNT" -eq 0 ]; then
  EMPTY=$((EMPTY + 1))
else
  EMPTY=0
fi
echo "$EMPTY" > "$COUNTER_FILE"

echo "$(date -u +%FT%TZ) players=$COUNT empty=$EMPTY/$EMPTY_LIMIT"

if [ "$EMPTY" -ge "$EMPTY_LIMIT" ]; then
  echo "Idle limit reached - saving world and stopping instance."
  docker exec palworld-server rest-cli save || true
  aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
fi
