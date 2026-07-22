"""Discord interactions handler for the Palworld server.

Verifies Ed25519 request signatures, answers Discord's PING, and implements
five slash commands:
  /palworld-start  -> ec2:StartInstances
  /palworld-stop   -> save the world via SSM, then ec2:StopInstances
  /palworld-update -> pull latest container image + recreate service via SSM
  /palworld-status -> instance state + current public IP + cached player count
  /palworld-health -> status + player count + persistent data usage

Environment variables (set by Terraform):
  DISCORD_PUBLIC_KEY       Discord app public key (hex) for signature checks
  INSTANCE_ID              EC2 instance ID of the game server
  PLAYER_COUNT_PARAM_NAME  SSM Parameter Store name holding the cached count
  DATA_USAGE_PARAM_NAME    SSM Parameter Store name holding cached data usage
  AWS_REGION_NAME          AWS region
"""

import json
import os
from urllib import request

import boto3
from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError

PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
APP_ID = os.environ["DISCORD_APPLICATION_ID"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
PARAM_NAME = os.environ["PLAYER_COUNT_PARAM_NAME"]
DATA_USAGE_PARAM_NAME = os.environ["DATA_USAGE_PARAM_NAME"]
REGION = os.environ.get("AWS_REGION_NAME", "us-east-1")
WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()

ec2 = boto3.client("ec2", region_name=REGION)
ssm = boto3.client("ssm", region_name=REGION)
lambda_client = boto3.client("lambda", region_name=REGION)

# Discord interaction/response type constants.
PING = 1
APPLICATION_COMMAND = 2
PONG = 1
CHANNEL_MESSAGE_WITH_SOURCE = 4
DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE = 5
ASYNC_SOURCE = "palworld-async-command"


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


def _defer_reply() -> dict:
    return _json(200, {"type": DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE})


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


def _interaction_followup(interaction_token: str, message: str) -> None:
    """Edit the deferred interaction response with the final command result."""
    if not interaction_token:
        return
    payload = json.dumps({"content": message}).encode("utf-8")
    url = f"https://discord.com/api/v10/webhooks/{APP_ID}/{interaction_token}/messages/@original"
    req = request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "PalsWithPals/1.0"},
        method="PATCH",
    )
    try:
        with request.urlopen(req, timeout=10):
            pass
    except Exception:
        # If Discord follow-up fails, do not raise (the AWS action may already have succeeded).
        pass


def _cached_player_count() -> str:
    try:
        resp = ssm.get_parameter(Name=PARAM_NAME)
        return resp["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        return "unknown"


def _cached_data_usage_percent() -> str:
    try:
        resp = ssm.get_parameter(Name=DATA_USAGE_PARAM_NAME)
        value = resp["Parameter"]["Value"]
        return f"{value}%" if value else "unknown"
    except ssm.exceptions.ParameterNotFound:
        return "unknown"


def _start() -> str:
    state = _instance_state()
    if state == "running":
        return "Server is already running."
    try:
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
    except ec2.exceptions.ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "UnsupportedOperation":
            return (
                "⚠️ Cannot start the server right now. It was stopped by a **spot interruption** "
                "and AWS does not allow manual restarts in this state. "
                "The server will restart automatically once spot capacity is available, "
                "or an admin can switch to an on-demand instance to avoid future interruptions."
            )
        raise
    _notify_webhook(":green_circle: Palworld server is **starting**.")
    return "Starting the Palworld server. Give it a couple of minutes to boot."


def _update() -> str:
    state = _instance_state()
    if state != "running":
        return "Server must be **running** before a manual update. Run `/palworld-start` first."

    resp = ssm.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName="AWS-RunShellScript",
        Parameters={
            "commands": [
                "set -euo pipefail",
                "cd /opt/palworld",
                "docker exec palworld-server rest-cli save || true",
                "docker compose pull palworld",
                "docker compose up -d --no-deps --force-recreate palworld",
            ]
        },
    )
    command_id = resp["Command"]["CommandId"]
    _notify_webhook(
        f":arrows_counterclockwise: Palworld server manual update triggered (SSM command `{command_id}`)."
    )
    return (
        "Triggered manual update (pull latest container image + recreate container). "
        f"SSM command id: `{command_id}`."
    )


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


def _health() -> str:
    instance = _instance_details()
    state = instance["State"]["Name"]
    usage = _cached_data_usage_percent()
    if state != "running":
        return f"Server state: **{state}**. Persistent data usage: **{usage}**."
    ip = instance.get("PublicIpAddress", "unknown")
    players = _cached_player_count()
    return (
        f"Server state: **running** at `{ip}:8211`. "
        f"Players online: **{players}**. Persistent data usage: **{usage}**."
    )


COMMANDS = {
    "palworld-start": _start,
    "palworld-stop": _stop,
    "palworld-update": _update,
    "palworld-status": _status,
    "palworld-health": _health,
}


def _enqueue_async_command(body: dict) -> None:
    lambda_client.invoke(
        FunctionName=os.environ["AWS_LAMBDA_FUNCTION_NAME"],
        InvocationType="Event",
        Payload=json.dumps({"source": ASYNC_SOURCE, "body": body}).encode("utf-8"),
    )


def _run_async_command(body: dict) -> None:
    name = body.get("data", {}).get("name")
    token = body.get("token", "")
    command = COMMANDS.get(name)
    if command is None:
        _interaction_followup(token, f"Unknown command: {name}")
        return
    try:
        result = command()
    except Exception as exc:  # noqa: BLE001 - surface errors to the user
        result = f"Error running {name}: {exc}"
    _interaction_followup(token, result)


def handler(event, context):
    if event.get("source") == ASYNC_SOURCE:
        _run_async_command(event.get("body") or {})
        return _json(200, {"ok": True})

    if not _verify(event):
        return _json(401, {"error": "invalid request signature"})

    body = json.loads(event.get("body") or "{}")

    if body.get("type") == PING:
        return _json(200, {"type": PONG})

    if body.get("type") == APPLICATION_COMMAND:
        name = body.get("data", {}).get("name")
        if name not in COMMANDS:
            return _reply(f"Unknown command: {name}")
        try:
            _enqueue_async_command(body)
            return _defer_reply()
        except Exception as exc:  # noqa: BLE001 - surface errors to the user
            return _reply(f"Error queueing {name}: {exc}")

    return _json(400, {"error": "unhandled interaction type"})
