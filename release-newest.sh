#!/bin/bash

# ──────────────────────────────────────────────────────────────
# release-newest.sh <product> [--push]
#
# Run after you've dropped a new versioned .fdt (and optionally an
# updated Firmware Update history PDF) into <product>-firmwares/.
#
# 1. Finds the latest versioned .fdt in <product>-firmwares/
# 2. Copies it over <product>-firmwares/newest/<fixed-name>.fdt
#    (reuses the existing fixed name; first time it creates
#    <product>-newest-firmware.fdt)
# 3. Shows what changed
#
# Without --push: stops there. You commit/push yourself.
# With --push:    stages ONLY the new .fdt, the newest/ file and
#                 firmware-update-history/, commits, pulls --rebase,
#                 pushes, waits for the workflow, and prints the
#                 verified links.
#
# Examples:
#   ./release-newest.sh duophony
#   ./release-newest.sh solis-ventus --push
#
# On any failure it prints which STAGE failed and why, and exits non-zero.
# DEPENDENCIES: git, gh (authenticated) for --push
# ──────────────────────────────────────────────────────────────

set -e
STAGE="startup"
trap 'echo ""; echo "✗ FAILED at stage: $STAGE (script line $LINENO)"; echo "  The error above this line is the reason."' ERR
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRODUCT="$1"
PUSH="$2"
REPO="gfisystem/downloads"

if [ -z "$PRODUCT" ] || [ ! -d "$PRODUCT-firmwares" ]; then
  echo "Usage: $0 <product> [--push]"
  echo "Products:"; ls -d *-firmwares | sed 's/-firmwares$//; s/^/  /'
  exit 1
fi

STAGE="finding latest firmware"
DIR="$PRODUCT-firmwares"
LATEST=$(ls "$DIR" | grep '\.fdt$' | sort -V | tail -1)
[ -z "$LATEST" ] && { echo "✗ No .fdt files in $DIR"; exit 1; }

STAGE="copying to newest/"
mkdir -p "$DIR/newest"
FIXED=$(ls "$DIR/newest" | grep '\.fdt$' | head -1)
[ -z "$FIXED" ] && FIXED="$PRODUCT-newest-firmware.fdt"

echo "Latest versioned firmware: $LATEST"
echo "Fixed name:                $FIXED"

if cmp -s "$DIR/$LATEST" "$DIR/newest/$FIXED"; then
  echo "newest/ already matches $LATEST (nothing to copy)"
else
  cp "$DIR/$LATEST" "$DIR/newest/$FIXED"
  echo "Copied $LATEST -> newest/$FIXED"
fi

echo ""
git status -s -- "$DIR" | grep -v DS_Store || echo "(no changes under $DIR)"

if [ "$PUSH" != "--push" ]; then
  echo ""
  echo "Not pushed. Re-run with --push, or commit yourself."
  exit 0
fi

# ── --push ────────────────────────────────────────────────────
STAGE="pre-flight checks"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "✗ Not on main"; exit 1; }
[ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && { echo "✗ A rebase is already in progress; finish it first"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh is not authenticated (run: gh auth login)"; exit 1; }

STAGE="staging files"
git add "$DIR/$LATEST" "$DIR/newest/$FIXED"
[ -d "$DIR/firmware-update-history" ] && git add "$DIR/firmware-update-history"
git reset -q -- '*.DS_Store' 2>/dev/null || true

if git diff --cached --quiet; then
  echo "Nothing staged — nothing to push."; exit 0
fi
echo "Staged:"; git diff --cached --name-status

STAGE="git commit"
git commit -q -m "add $PRODUCT firmware ${LATEST%.fdt}, update newest and update history"

STAGE="git pull --rebase"
if ! git pull --rebase --autostash origin main; then
  echo "✗ Rebase conflict. Resolve it, then: git rebase --continue && git push origin main"
  echo "  (or abort with: git rebase --abort — your commit is kept)"
  exit 1
fi

STAGE="git push"
git push origin main
SHA=$(git rev-parse HEAD)

STAGE="waiting for workflow run to start"
RUN=""
for i in $(seq 1 24); do
  RUN=$(gh run list --workflow=create-releases.yml --repo "$REPO" --commit "$SHA" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [ -n "$RUN" ] && break
  sleep 5
done
[ -z "$RUN" ] && { echo "✗ No workflow run appeared for commit ${SHA:0:7} after 2 min (does the pushed path match the workflow triggers?)"; exit 1; }
echo "Workflow run $RUN for ${SHA:0:7}"

STAGE="workflow run"
if ! gh run watch "$RUN" --repo "$REPO" --exit-status >/dev/null; then
  echo "✗ Workflow failed. Last failing log lines:"
  gh run view "$RUN" --repo "$REPO" --log-failed | tail -30
  exit 1
fi

STAGE="verifying live release"
TAG="$PRODUCT-newest"
BAD=0
LOCAL_SIZE=$(wc -c < "$DIR/newest/$FIXED" | tr -d ' ')
echo ""
echo "Live assets in $TAG:"
while IFS=$'\t' read -r name size; do
  url="https://github.com/$REPO/releases/download/$TAG/$name"
  code=$(curl -sIL -o /dev/null -w "%{http_code}" "$url")
  note=""
  [ "$code" = "200" ] || { BAD=1; note="  <-- NOT OK"; }
  if [ "$name" = "$FIXED" ] && [ "$size" != "$LOCAL_SIZE" ]; then
    BAD=1; note="  <-- SIZE MISMATCH (live $size vs local $LOCAL_SIZE)"
  fi
  echo "  $code  $url$note"
done < <(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | [.name, .size] | @tsv')

if ! gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[].name' | grep -qx "$FIXED"; then
  echo "✗ $FIXED is missing from $TAG"; BAD=1
fi
[ "$BAD" = "0" ] || { echo ""; echo "✗ Verification failed (see lines above)"; exit 1; }
echo ""
echo "✓ Done — all links verified."
