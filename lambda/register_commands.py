"""Register the three global slash commands with Discord.

Run this once (and again whenever command definitions change). Reads secrets
from the environment so nothing sensitive is hardcoded:

  DISCORD_APPLICATION_ID  your app's application id
  DISCORD_BOT_TOKEN       your bot token (Bot <token> is added automatically)

Usage:
  DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... python register_commands.py
"""

import os

import requests

APP_ID = os.environ["DISCORD_APPLICATION_ID"]
BOT_TOKEN = os.environ["DISCORD_BOT_TOKEN"]

URL = f"https://discord.com/api/v10/applications/{APP_ID}/commands"

COMMANDS = [
    {"name": "palworld-start", "description": "Start the Palworld server", "type": 1},
    {"name": "palworld-stop", "description": "Save and stop the Palworld server", "type": 1},
    {"name": "palworld-status", "description": "Show server state and player count", "type": 1},
]


def main() -> None:
    headers = {"Authorization": f"Bot {BOT_TOKEN}"}
    for command in COMMANDS:
        resp = requests.post(URL, json=command, headers=headers, timeout=15)
        resp.raise_for_status()
        print(f"Registered /{command['name']}")


if __name__ == "__main__":
    main()
