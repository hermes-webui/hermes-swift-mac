#!/bin/bash
# Release a new version: push main, then push the tag as a separate operation
# so the Build and Release workflow reliably fires.
#
# Background: when main and a new tag are pushed in a single `git push`
# invocation (e.g. `git push --follow-tags` or `git push origin main vX.Y.Z`),
# GitHub sometimes delivers only one of the two push events. This is what
# happened to v1.0.5 — the tag landed on origin but neither the Test nor the
# Build-Release workflow fired, and the release had to be kicked off manually
# via workflow_dispatch. Pushing the tag in its own operation avoids that.
#
# Usage: scripts/release.sh v1.0.6

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 vX.Y.Z" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like vX.Y.Z (got '$VERSION')" >&2
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "error: release must be cut from main (currently on '$BRANCH')" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes" >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
    echo "error: tag $VERSION already exists locally" >&2
    exit 1
fi

echo "→ Fetching latest refs from origin..."
git fetch origin --tags --prune

if git rev-parse --verify --quiet "refs/tags/origin/$VERSION" >/dev/null 2>&1 \
    || git ls-remote --tags origin "refs/tags/$VERSION" | grep -q "$VERSION"; then
    echo "error: tag $VERSION already exists on origin" >&2
    exit 1
fi

echo "→ Pushing main..."
git push origin main

echo "→ Creating annotated tag $VERSION at HEAD..."
git tag -a "$VERSION" -m "Release $VERSION"

# Tag-only push — do NOT combine with a branch push.
echo "→ Pushing tag $VERSION (separate push)..."
git push origin "refs/tags/$VERSION"

echo
echo "✓ Tag $VERSION pushed. The Build and Release workflow should start within a few seconds."
echo "  Watch it:  gh run watch --exit-status"
echo "  Or open:   https://github.com/hermes-webui/hermes-swift-mac/actions"
