"""Register the three global slash commands with Discord.

Run this once (and again whenever command definitions change). Reads secrets
from the environment so nothing sensitive is hardcoded:

  DISCORD_APPLICATION_ID  your app's application id
  DISCORD_BOT_TOKEN       your bot token (Bot <token> is added automatically)

Usage:
  DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... python3 register_commands.py
"""

import os
import json
from urllib import request, error

APP_ID = os.environ["DISCORD_APPLICATION_ID"]
BOT_TOKEN = os.environ["DISCORD_BOT_TOKEN"]

URL = f"https://discord.com/api/v10/applications/{APP_ID}/commands"

COMMANDS = [
    {"name": "palworld-start", "description": "Start the Palworld server", "type": 1},
    {"name": "palworld-stop", "description": "Save and stop the Palworld server", "type": 1},
    {"name": "palworld-status", "description": "Show server state and player count", "type": 1},
]


def main() -> None:
    headers = {
        "Authorization": f"Bot {BOT_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        # Some Discord edge paths are stricter without an explicit user agent.
        "User-Agent": "PalsWithPalsCommandRegistrar/1.0",
    }
    print(f"Registering global commands at: {URL}")
    for command in COMMANDS:
        req = request.Request(
            URL,
            data=json.dumps(command).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with request.urlopen(req, timeout=15) as resp:
                if resp.status < 200 or resp.status >= 300:
                    raise RuntimeError(f"Discord API error: HTTP {resp.status}")
        except error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            hint = ""
            if exc.code == 403:
                hint = (
                    "\nHint: 403 usually means app/token mismatch or missing access. "
                    "Verify DISCORD_APPLICATION_ID belongs to the same app as DISCORD_BOT_TOKEN, "
                    "and for guild registration confirm the bot is invited to that server with "
                    "the applications.commands scope."
                )
            raise RuntimeError(f"Discord API error: HTTP {exc.code}: {body}{hint}") from exc
        print(f"Registered /{command['name']}")


if __name__ == "__main__":
    main()
