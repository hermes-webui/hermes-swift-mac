#!/usr/bin/env python3
"""Prepend a new <item> entry to appcast.xml for a newly released version.

Reads required metadata from environment variables. Idempotent: if the
version is already present in the appcast, exits without making changes.

Env vars:
  VERSION      - "1.0.5"
  PUBDATE      - "Thu, 17 Apr 2026 03:30:00 +0000"
  RELEASE_URL  - direct download URL for the DMG
  NOTES_URL    - GitHub release page URL for release notes
  SIG          - Sparkle ed25519 signature
  SIZE         - DMG size in bytes
"""
import os
import pathlib
import sys

APPCAST = pathlib.Path("appcast.xml")
MARKER = "<language>en</language>"

ENV_KEYS = ("VERSION", "PUBDATE", "RELEASE_URL", "NOTES_URL", "SIG", "SIZE")


def main() -> int:
    env = {k: os.environ.get(k, "") for k in ENV_KEYS}
    missing = [k for k, v in env.items() if not v]
    if missing:
        print(f"error: missing env vars: {', '.join(missing)}", file=sys.stderr)
        return 1

    txt = APPCAST.read_text()
    if MARKER not in txt:
        print(f"error: marker {MARKER!r} missing from appcast.xml", file=sys.stderr)
        return 1

    version_tag = f"<sparkle:version>{env['VERSION']}</sparkle:version>"
    if version_tag in txt:
        print(f"appcast.xml already contains version {env['VERSION']}; skipping")
        return 0

    item = (
        "        <item>\n"
        f"            <title>Version {env['VERSION']}</title>\n"
        f"            <pubDate>{env['PUBDATE']}</pubDate>\n"
        f"            <sparkle:version>{env['VERSION']}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{env['VERSION']}</sparkle:shortVersionString>\n"
        "            <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>\n"
        f"            <sparkle:releaseNotesLink>{env['NOTES_URL']}</sparkle:releaseNotesLink>\n"
        "            <enclosure\n"
        f'                url="{env["RELEASE_URL"]}"\n'
        f'                sparkle:edSignature="{env["SIG"]}"\n'
        f'                length="{env["SIZE"]}"\n'
        '                type="application/octet-stream"/>\n'
        "        </item>\n"
    )

    txt = txt.replace(MARKER, MARKER + "\n\n" + item, 1)
    APPCAST.write_text(txt)
    print(f"appcast.xml updated with version {env['VERSION']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
