#!/usr/bin/env bash
# Zero-migration instance-type upgrade.
#
# Because the world save lives on a persistent EBS data volume that stays
# attached across stop/start, changing the instance type needs no data move.
#
# Usage:
#   ./resize.sh <instance-id> <new-instance-type> [aws-region]
# Example:
#   ./resize.sh i-0123456789abcdef0 r6i.xlarge us-east-1
set -euo pipefail

INSTANCE_ID=${1:?instance id required}
NEW_TYPE=${2:?new instance type required}
REGION=${3:-us-east-1}

echo "Stopping $INSTANCE_ID ..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "Changing instance type to $NEW_TYPE ..."
aws ec2 modify-instance-attribute --region "$REGION" \
  --instance-id "$INSTANCE_ID" --instance-type "{\"Value\":\"$NEW_TYPE\"}"

echo "Starting $INSTANCE_ID ..."
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "Done. Instance $INSTANCE_ID is now $NEW_TYPE."
