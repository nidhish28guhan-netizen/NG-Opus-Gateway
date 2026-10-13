"""Patch Claude Code's settings.json to point at the gateway.

Usage: patch_claude_settings.py <path> <base_url> <api_key>

Reads the existing settings if present, merges the env block in, and writes it
back. Never drops keys the user already set.
"""
import json
import sys


def main() -> int:
    path, base_url, api_key = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}

    if not isinstance(data, dict):
        data = {}

    env = data.get("env")
    if not isinstance(env, dict):
        env = {}

    env["ANTHROPIC_BASE_URL"] = base_url
    env["ANTHROPIC_AUTH_TOKEN"] = api_key
    data["env"] = env

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
