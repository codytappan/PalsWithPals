"""Discord interactions handler for the Palworld server.

Verifies Ed25519 request signatures, answers Discord's PING, and implements
three slash commands:
  /palworld-start  -> ec2:StartInstances
  /palworld-stop   -> save the world via SSM, then ec2:StopInstances
  /palworld-status -> instance state + current public IP + cached player count

Environment variables (set by Terraform):
  DISCORD_PUBLIC_KEY       Discord app public key (hex) for signature checks
  INSTANCE_ID              EC2 instance ID of the game server
  PLAYER_COUNT_PARAM_NAME  SSM Parameter Store name holding the cached count
  AWS_REGION_NAME          AWS region
"""

import json
import os
from urllib import request

import boto3
from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError

PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
PARAM_NAME = os.environ["PLAYER_COUNT_PARAM_NAME"]
REGION = os.environ.get("AWS_REGION_NAME", "us-east-1")
WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()

ec2 = boto3.client("ec2", region_name=REGION)
ssm = boto3.client("ssm", region_name=REGION)

# Discord interaction/response type constants.
PING = 1
APPLICATION_COMMAND = 2
PONG = 1
CHANNEL_MESSAGE_WITH_SOURCE = 4


def _verify(event) -> bool:
    """Verify the Ed25519 signature on the incoming request."""
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    signature = headers.get("x-signature-ed25519")
    timestamp = headers.get("x-signature-timestamp")
    body = event.get("body") or ""
    if not signature or not timestamp:
        return False
    try:
        VerifyKey(bytes.fromhex(PUBLIC_KEY)).verify(
            (timestamp + body).encode(), bytes.fromhex(signature)
        )
        return True
    except BadSignatureError:
        return False


def _reply(content: str) -> dict:
    return _json(200, {"type": CHANNEL_MESSAGE_WITH_SOURCE, "data": {"content": content}})


def _json(status: int, payload: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _instance_state() -> str:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def _instance_details() -> dict:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0]


def _notify_webhook(message: str) -> None:
    """Best-effort Discord webhook post; never break command handling."""
    if not WEBHOOK_URL:
        return
    payload = json.dumps({"content": message}).encode("utf-8")
    req = request.Request(
        WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "PalsWithPals/1.0"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=10):
            pass
    except Exception:
        # Notification failures should never block start/stop control.
        pass


def _cached_player_count() -> str:
    try:
        resp = ssm.get_parameter(Name=PARAM_NAME)
        return resp["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        return "unknown"


def _start() -> str:
    state = _instance_state()
    if state == "running":
        return "Server is already running."
    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    _notify_webhook(":green_circle: Palworld server is **starting**.")
    return "Starting the Palworld server. Give it a couple of minutes to boot and update."


def _stop() -> str:
    state = _instance_state()
    if state in ("stopped", "stopping"):
        return "Server is already stopped or stopping."
    # Save the world before stopping. Best-effort: the idle watcher also saves.
    ssm.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": ["docker exec palworld-server rest-cli save"]},
    )
    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    _notify_webhook(":red_circle: Palworld server is **stopping** (world save triggered).")
    return "Saved the world and stopping the server."


def _status() -> str:
    instance = _instance_details()
    state = instance["State"]["Name"]
    if state != "running":
        return f"Server state: **{state}**."
    ip = instance.get("PublicIpAddress", "unknown")
    return f"Server state: **running** at `{ip}:8211`. Players online: **{_cached_player_count()}**."


COMMANDS = {
    "palworld-start": _start,
    "palworld-stop": _stop,
    "palworld-status": _status,
}


def handler(event, context):
    if not _verify(event):
        return _json(401, {"error": "invalid request signature"})

    body = json.loads(event.get("body") or "{}")

    if body.get("type") == PING:
        return _json(200, {"type": PONG})

    if body.get("type") == APPLICATION_COMMAND:
        name = body.get("data", {}).get("name")
        command = COMMANDS.get(name)
        if command is None:
            return _reply(f"Unknown command: {name}")
        try:
            return _reply(command())
        except Exception as exc:  # noqa: BLE001 - surface errors to the user
            return _reply(f"Error running {name}: {exc}")

    return _json(400, {"error": "unhandled interaction type"})
