#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/opt/palworld/.env
COMPOSE_DIR=/opt/palworld

# Wait briefly for Docker on boot.
for _ in $(seq 1 30); do
  if systemctl is-active --quiet docker; then
    break
  fi
  sleep 2
done

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
PUBLIC_IP=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || true)

if [ -n "$PUBLIC_IP" ] && [ -f "$ENV_FILE" ]; then
  if grep -q '^PUBLIC_IP=' "$ENV_FILE"; then
    sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP=$PUBLIC_IP/" "$ENV_FILE"
  else
    echo "PUBLIC_IP=$PUBLIC_IP" >> "$ENV_FILE"
  fi
fi

cd "$COMPOSE_DIR"
docker compose up -d --force-recreate

