"""SNS -> Discord webhook notifier for CloudWatch alarms."""

import json
import os
from urllib import request

WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()


def _post(message: str) -> None:
    if not WEBHOOK_URL:
        return
    payload = json.dumps({"content": message}).encode("utf-8")
    req = request.Request(
        WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "PalsWithPalsAlarmNotifier/1.0"},
        method="POST",
    )
    with request.urlopen(req, timeout=10):
        pass


def _format_alarm_message(record: dict) -> str:
    subject = record.get("Sns", {}).get("Subject", "CloudWatch Alarm")
    raw_message = record.get("Sns", {}).get("Message", "")
    try:
        payload = json.loads(raw_message)
    except json.JSONDecodeError:
        return f":warning: **{subject}**\n```{raw_message[:1500]}```"

    alarm = payload.get("AlarmName", "unknown")
    state = payload.get("NewStateValue", "UNKNOWN")
    reason = payload.get("NewStateReason", "")
    region = payload.get("Region", "")
    icon = ":rotating_light:" if state == "ALARM" else ":white_check_mark:" if state == "OK" else ":information_source:"
    lines = [f"{icon} **{alarm}** is now **{state}**"]
    if region:
        lines.append(f"Region: `{region}`")
    if reason:
        trimmed = reason if len(reason) <= 800 else reason[:797] + "..."
        lines.append(f"Reason: {trimmed}")
    return "\n".join(lines)


def handler(event, context):
    records = event.get("Records", [])
    for record in records:
        message = _format_alarm_message(record)
        _post(message)
    return {"ok": True, "records": len(records)}

