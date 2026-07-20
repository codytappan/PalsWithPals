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

source /opt/palworld/idle.env  # AWS_REGION, PLAYER_COUNT_PARAM_NAME, DATA_USAGE_PARAM_NAME, EMPTY_LIMIT

COUNTER_FILE=/opt/palworld/empty_count
COUNT_FILE=/opt/palworld/player_count

# IMDSv2 token + instance id.
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# Count players from rest-cli JSON output: {"players":[...]}.
if PLAYERS_RAW=$(docker exec palworld-server rest-cli players 2>/dev/null); then
  COUNT=$(python3 - <<'PY' "$PLAYERS_RAW"
import json
import sys
try:
    payload = json.loads(sys.argv[1])
    players = payload.get("players", [])
    print(len(players) if isinstance(players, list) else 0)
except Exception:
    print(0)
PY
)
else
  COUNT=0
fi

# Cache the count locally and in SSM.
echo "$COUNT" > "$COUNT_FILE"
aws ssm put-parameter --region "$AWS_REGION" \
  --name "$PLAYER_COUNT_PARAM_NAME" --type String \
  --value "$COUNT" --overwrite >/dev/null 2>&1 || true

# Cache persistent data usage percent for health reporting.
DATA_USAGE_PCT=$(df -P /opt/palworld/data | awk 'NR==2 {gsub(/%/, "", $5); print $5}' || true)
if [ -n "$DATA_USAGE_PCT" ]; then
  aws ssm put-parameter --region "$AWS_REGION" \
    --name "$DATA_USAGE_PARAM_NAME" --type String \
    --value "$DATA_USAGE_PCT" --overwrite >/dev/null 2>&1 || true
fi

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
  WEBHOOK_URL=$(grep '^DISCORD_WEBHOOK_URL=' /opt/palworld/.env | cut -d= -f2- || true)
  if [ -n "$WEBHOOK_URL" ]; then
    curl -sS -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d '{"content":":crescent_moon: Palworld server is **auto-stopping** due to inactivity."}' \
      >/dev/null || true
  fi
  docker exec palworld-server rest-cli save || true
  aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
fi
