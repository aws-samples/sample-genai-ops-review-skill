#!/usr/bin/env bash
# lens-lookup.sh — look up lens-canonical title, description, displayText,
# documentation URL, and improvement guidance for one or more checks.
#
# The four lens JSON files (loaded by load_lens_index in _common.sh) are the
# single source of truth for every check's wording. This helper exposes that
# index so sub-skills can pull just the entries they care about, instead of
# duplicating prose pointers in every markdown.
#
# Selection (combinable; results are the union of every selector):
#   --check-id <id>          repeatable
#   --owner <owner>          owner key from references/owned-checks.json
#                            (e.g. "WA:Security", "NIST:Govern")
#   --pillar <lens-pillar>   lens pillar id (e.g. "security",
#                            "resource_security", "govern")
#
# Output (default: markdown table). One of:
#   --format markdown        markdown table with id | title | summary | doc
#                            (summary is the helpfulResource.displayText
#                            truncated to 160 chars + ellipsis)
#   --format json            JSON array of full lens records
#   --format full            multi-line markdown blocks per check (title +
#                            full displayText + improvementPlan + url)
#
# Usage:
#   lens-lookup.sh --owner "WA:Security"
#   lens-lookup.sh --check-id GENSEC02_BP01 --check-id GENSEC04_BP02
#   lens-lookup.sh --pillar resource_security --format full
#
# Exit codes:
#   0  one or more entries returned
#   1  argument or path error
#   2  no entries matched the selectors

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  lens-lookup.sh [--check-id <id>]... [--owner <owner>]... [--pillar <id>]...
                 [--format markdown|json|full]

Selectors (combinable; results are the union):
  --check-id <id>          a check_id (repeatable)
  --owner <owner>          owner key from references/owned-checks.json
                           (e.g. "WA:Security", "NIST:Govern")
  --pillar <lens-pillar>   lens pillar id (e.g. "security",
                           "resource_security", "govern")

Output:
  --format markdown        (default) compact markdown table
  --format json            JSON array of full lens records
  --format full            multi-line markdown blocks per check

Exit codes:
  0  one or more entries returned
  1  argument or path error
  2  no entries matched the selectors
USAGE_EOF
}

CHECK_IDS=()
OWNERS=()
PILLARS=()
FORMAT="markdown"

while [ $# -gt 0 ]; do
  case "$1" in
    --check-id)   CHECK_IDS+=("${2:-}"); shift 2 ;;
    --check-id=*) CHECK_IDS+=("${1#--check-id=}"); shift ;;
    --owner)      OWNERS+=("${2:-}"); shift 2 ;;
    --owner=*)    OWNERS+=("${1#--owner=}"); shift ;;
    --pillar)     PILLARS+=("${2:-}"); shift 2 ;;
    --pillar=*)   PILLARS+=("${1#--pillar=}"); shift ;;
    --format)     FORMAT="${2:-}"; shift 2 ;;
    --format=*)   FORMAT="${1#--format=}"; shift ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
  esac
done

case "$FORMAT" in
  markdown|json|full) ;;
  *) echo "ERROR: --format must be one of markdown|json|full (got '${FORMAT}')" >&2; exit 1 ;;
esac

if [ "${#CHECK_IDS[@]}" -eq 0 ] && [ "${#OWNERS[@]}" -eq 0 ] && [ "${#PILLARS[@]}" -eq 0 ]; then
  echo "ERROR: at least one of --check-id, --owner, --pillar is required" >&2
  usage >&2
  exit 1
fi

SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OWNED_FILE="${SKILL_ROOT}/references/owned-checks.json"

# ---------------------------------------------------------------------------
# Resolve every selector down to a single set of check_ids, then look up
# their lens records.
# ---------------------------------------------------------------------------
LENS_INDEX_JSON=$(load_lens_index)

# Expand --owner into check_ids using owned-checks.json.
if [ "${#OWNERS[@]}" -gt 0 ]; then
  if [ ! -f "$OWNED_FILE" ]; then
    echo "ERROR: owned-checks.json not found: ${OWNED_FILE}" >&2
    exit 1
  fi
  OWNERS_JSON=$(printf '%s\n' "${OWNERS[@]}" | jq -R . | jq -s .)
  while IFS= read -r id; do
    [ -n "$id" ] && CHECK_IDS+=("$id")
  done < <(jq -r --argjson owners "$OWNERS_JSON" '
      .owners | to_entries[]
      | select(.key as $k | $owners | index($k))
      | .value.ids[]
    ' "$OWNED_FILE")
fi

# Expand --pillar into check_ids by walking the lens index.
if [ "${#PILLARS[@]}" -gt 0 ]; then
  PILLARS_JSON=$(printf '%s\n' "${PILLARS[@]}" | jq -R . | jq -s .)
  while IFS= read -r id; do
    [ -n "$id" ] && CHECK_IDS+=("$id")
  done < <(printf '%s' "$LENS_INDEX_JSON" | jq -r --argjson pillars "$PILLARS_JSON" '
      .[] | select(.pillar_id as $p | $pillars | index($p)) | .check_id
    ')
fi

# Deduplicate (preserve original order via awk's own internal seen[] map).
CHECK_IDS_DEDUP=()
while IFS= read -r id; do
  [ -n "$id" ] && CHECK_IDS_DEDUP+=("$id")
done < <(printf '%s\n' "${CHECK_IDS[@]}" | awk '!seen[$0]++')

if [ "${#CHECK_IDS_DEDUP[@]}" -eq 0 ]; then
  echo "ERROR: no check_ids resolved from selectors" >&2
  exit 2
fi

IDS_JSON=$(printf '%s\n' "${CHECK_IDS_DEDUP[@]}" | jq -R . | jq -s .)

RESULT_JSON=$(printf '%s' "$LENS_INDEX_JSON" | jq --argjson ids "$IDS_JSON" '
    [ .[] | select(.check_id as $c | $ids | index($c)) ]
    # Preserve the order of $ids in the result.
    | sort_by(.check_id as $c | $ids | index($c))
')

MATCHED=$(printf '%s' "$RESULT_JSON" | jq 'length')
if [ "$MATCHED" -eq 0 ]; then
  echo "ERROR: no lens entries matched the resolved check_ids: ${CHECK_IDS_DEDUP[*]}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------
case "$FORMAT" in
  json)
    printf '%s\n' "$RESULT_JSON"
    ;;
  markdown)
    printf '%s' "$RESULT_JSON" | jq -r '
      "| Check ID | Title | About | Documentation |",
      "|----------|-------|-------|---------------|",
      ( .[] |
        ((.display_text // "") | gsub("[\r\n]+"; " ") |
          (if length > 160 then .[0:157] + "..." else . end)) as $about
        | "| `\(.check_id)` | \(.title) | \($about) | <\(.url)> |"
      )
    '
    ;;
  full)
    printf '%s' "$RESULT_JSON" | jq -r '
      .[] |
      "### `\(.check_id)` — \(.title)\n\n",
      "**Lens:** \(.lens_name) → \(.pillar_name) (`\(.pillar_id)`) → question `\(.question_id)`\n\n",
      "**About:** \(.display_text)\n\n",
      (if (.improvement_text // "") != "" and (.improvement_text != .title)
         then "**Improvement plan:** \(.improvement_text)\n\n" else "" end),
      "**Documentation:** <\(.url)>\n\n",
      "---\n\n"
    '
    ;;
esac

exit 0
