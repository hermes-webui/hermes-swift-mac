#!/usr/bin/env python3
"""Print the CHANGELOG.md section body for a specific tag.

Given a tag like "v1.0.7", finds the heading "## [v1.0.7] — ..." in
CHANGELOG.md and prints everything between that heading and the next
"## " heading (or end of file). If the tag has no section yet, prints
a fallback placeholder so the release page is never empty.

Usage: extract_changelog.py vX.Y.Z
"""
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: extract_changelog.py vX.Y.Z\n")
        return 1
    tag = sys.argv[1]

    path = Path("CHANGELOG.md")
    if not path.exists():
        print(f"_No CHANGELOG.md found. See commits since the previous release._")
        return 0

    text = path.read_text()
    pattern = re.compile(
        rf"^##\s+\[{re.escape(tag)}\][^\n]*\n(.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    if match is None:
        print(f"_No CHANGELOG.md entry for {tag} yet — see commits since the previous release._")
        return 0

    body = match.group(1).strip()
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
