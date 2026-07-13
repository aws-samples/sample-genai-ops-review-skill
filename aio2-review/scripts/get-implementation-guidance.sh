#!/usr/bin/env bash
# get-implementation-guidance.sh
#
# Outputs the implementation guidance for a single WA check from the
# pre-fetched wa-implementation-guidance.json file.
#
# Usage:
#   get-implementation-guidance.sh <CHECK_ID>
#   get-implementation-guidance.sh GENSEC01_BP01
#   get-implementation-guidance.sh --list
#
# Output (JSON):
#   { "check_id": "...", "title": "...", "url": "...",
#     "implementation_guidance": "...", "implementation_steps": [...] }
#
# With --list, outputs all available check IDs (one per line).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDANCE_FILE="${SCRIPT_DIR}/../references/wa-implementation-guidance.json"

usage() {
  echo "Usage: $(basename "$0") <CHECK_ID>"
  echo "       $(basename "$0") --list"
  echo ""
  echo "Outputs implementation guidance for a WA GenAI Lens check."
  echo ""
  echo "Options:"
  echo "  --list    List all available check IDs"
  echo "  --help    Show this help"
  exit "${1:-0}"
}

if [ $# -lt 1 ]; then
  usage 1
fi

case "$1" in
  --help|-h)
    usage 0
    ;;
  --list)
    if [ ! -f "$GUIDANCE_FILE" ]; then
      echo "ERROR: $GUIDANCE_FILE not found. Run fetch-wa-implementation-guidance.sh first." >&2
      exit 1
    fi
    jq -r '.checks | keys[]' "$GUIDANCE_FILE"
    exit 0
    ;;
esac

CHECK_ID="$1"

if [ ! -f "$GUIDANCE_FILE" ]; then
  echo "ERROR: $GUIDANCE_FILE not found. Run fetch-wa-implementation-guidance.sh first." >&2
  exit 1
fi

# Look up the check
RESULT=$(jq --arg id "$CHECK_ID" '
  .checks[$id] // null
  | if . == null then null
    else {check_id: $id} + .
    end
' "$GUIDANCE_FILE")

if [ "$RESULT" = "null" ]; then
  echo "ERROR: Check ID '$CHECK_ID' not found in $GUIDANCE_FILE" >&2
  echo "Run with --list to see available check IDs." >&2
  exit 1
fi

echo "$RESULT"
