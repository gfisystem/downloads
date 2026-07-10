#!/bin/bash

# ──────────────────────────────────────────────────────────────
# generate-download-links.sh
# Fetches all release asset download URLs from GitHub and saves
# them to generated-download-links.txt (next to this script)
#
# DEPENDENCIES:
#   - GitHub CLI (gh)     https://cli.github.com
#                         Install on Mac: brew install gh
#   - jq                  https://jqlang.github.io/jq
#                         Install on Mac: brew install jq
#   - gh must be authenticated: run `gh auth login` if not done yet
#
# USAGE:
#   chmod +x generate-download-links.sh   (first time only)
#   ./generate-download-links.sh
# ──────────────────────────────────────────────────────────────

REPO="gfisystem/downloads"
OUTPUT="generated-download-links.txt"
PER_PAGE=100

# Get script's own directory so output file is always next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="$SCRIPT_DIR/$OUTPUT"

echo "Fetching release links from $REPO..."

# Clear or create the output file
> "$OUTPUT_PATH"

page=1
while true; do
  echo "  → Fetching page $page..."

  # Fetch one page of releases from GitHub API
  # Uses process substitution to capture output and check if empty
  results=$(gh api "repos/$REPO/releases?per_page=$PER_PAGE&page=$page" \
    --jq '.[].assets[].browser_download_url')

  # If results are empty, we've passed the last page — stop looping
  # This is the "sentinel value" pattern: an empty response signals completion
  if [ -z "$results" ]; then
    break
  fi

  echo "$results" >> "$OUTPUT_PATH"
  ((page++))
done

total=$(wc -l < "$OUTPUT_PATH" | tr -d ' ')
echo ""
echo "✅ Done — $total links saved to $OUTPUT"
echo "   $OUTPUT_PATH"

# Auto-open the file
open "$OUTPUT_PATH"
