#!/usr/bin/env bash
# set-narrative.sh — set narrative slices of report.json deterministically.
#
# Sections owned by this helper:
#   exec-prose        → executive_summary.prose            (string)
#   exec-strengths    → executive_summary.strengths        (array of strings)
#   exec-critical     → executive_summary.critical_high_findings (array of strings)
#   metadata.<field>  → metadata.<field>                   (string OR JSON via --json)
#
# All updates are atomic: jq builds a new report.json from the existing one,
# we write to a temp file under flock, then mv into place. Validate-report.sh
# is run with --quiet at the end and rolls back on per-record failure.
#
# Usage:
#   set-narrative.sh --data-dir <dir> --section <name> \
#                    (--text "<text>" | --text-file <file> | --json '<json>')
#
# Sections:
#   exec-prose        --text|--text-file (string)
#   exec-strengths    --text|--text-file (one item per non-blank line) | --json (array)
#   exec-critical     same as exec-strengths
#   metadata.<field>  --text|--text-file (string) | --json (any JSON value)
#
# Exit codes:
#   0  success
#   1  argument or path error
#   2  invalid --section
#   3  post-update validation failure (rollback performed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  set-narrative.sh --data-dir <dir> --section <name>
                   (--text "<text>" | --text-file <file> | --json '<json>')

Sections (closed set):
  exec-prose            executive_summary.prose
                        --text or --text-file (string).
  exec-strengths        executive_summary.strengths
                        --text or --text-file (one item per non-blank line),
                        or --json with a JSON array of strings.
  exec-critical         executive_summary.critical_high_findings
                        same input rules as exec-strengths.
  metadata.<field>      metadata.<field>
                        --text/--text-file for a string, or --json for any
                        JSON value (e.g. metadata.frameworks=["WA","NIST"]).

Exactly one of --text, --text-file, --json must be supplied.

Exit codes:
  0  success
  1  argument or path error
  2  invalid --section
  3  post-update validation failure (rollback performed)
USAGE_EOF
}

DATA_DIR=""
SECTION=""
TEXT=""
TEXT_FILE=""
JSON_VALUE=""
JSON_SET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)    DATA_DIR="${2:-}"; shift 2 ;;
    --data-dir=*)  DATA_DIR="${1#--data-dir=}"; shift ;;
    --section)     SECTION="${2:-}"; shift 2 ;;
    --section=*)   SECTION="${1#--section=}"; shift ;;
    --text)        TEXT="${2:-}"; shift 2 ;;
    --text=*)      TEXT="${1#--text=}"; shift ;;
    --text-file)   TEXT_FILE="${2:-}"; shift 2 ;;
    --text-file=*) TEXT_FILE="${1#--text-file=}"; shift ;;
    --json)        JSON_VALUE="${2:-}"; JSON_SET=1; shift 2 ;;
    --json=*)      JSON_VALUE="${1#--json=}"; JSON_SET=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
  esac
done

if [ -z "$DATA_DIR" ] || [ -z "$SECTION" ]; then
  echo "ERROR: --data-dir and --section are required" >&2
  usage >&2
  exit 1
fi
REPORT_JSON="${DATA_DIR}/report.json"
if [ ! -f "$REPORT_JSON" ]; then
  echo "ERROR: report.json not found: ${REPORT_JSON}" >&2
  exit 1
fi

# Mutually exclusive input flags; exactly one must be set.
INPUT_COUNT=0
[ -n "$TEXT" ] && INPUT_COUNT=$((INPUT_COUNT + 1))
[ -n "$TEXT_FILE" ] && INPUT_COUNT=$((INPUT_COUNT + 1))
[ "$JSON_SET" -eq 1 ] && INPUT_COUNT=$((INPUT_COUNT + 1))

if [ "$INPUT_COUNT" -ne 1 ]; then
  echo "ERROR: exactly one of --text, --text-file, --json must be supplied" >&2
  exit 1
fi

if [ -n "$TEXT_FILE" ]; then
  if [ ! -f "$TEXT_FILE" ]; then
    echo "ERROR: --text-file not found: ${TEXT_FILE}" >&2
    exit 1
  fi
  TEXT="$(cat "$TEXT_FILE")"
fi

# --- Section dispatch -------------------------------------------------------
# JQ_PATH: jq path expression that points to the slot in report.json.
# JQ_VALUE: jq expression (referencing $val) that produces the value to assign.
# We pass the raw text as $val (string) or $val (parsed JSON) depending on
# which input flag was set.
JQ_PATH=""
VALUE_KIND=""   # "string" | "string-list" | "json"

case "$SECTION" in
  exec-prose)
    JQ_PATH=".executive_summary.prose"
    VALUE_KIND="string"
    if [ -n "$TEXT" ] && [ -z "$TEXT_FILE" ]; then
      printf '%s\n' "ERROR: --section exec-prose requires --text-file (not --text). The 3-paragraph structure depends on \\n\\n separators which are lost when passed as inline shell arguments. Write to a file first, then use --text-file." >&2
      exit 1
    fi
    ;;
  exec-strengths)
    JQ_PATH=".executive_summary.strengths"
    VALUE_KIND="string-list"
    ;;
  exec-critical)
    JQ_PATH=".executive_summary.critical_high_findings"
    VALUE_KIND="string-list"
    ;;
  metadata.*)
    field="${SECTION#metadata.}"
    if [ -z "$field" ] || ! printf '%s' "$field" | grep -qE '^[a-z_][a-z0-9_]*$'; then
      echo "ERROR: invalid metadata field name: ${field}" >&2
      exit 2
    fi
    JQ_PATH=".metadata.${field}"
    VALUE_KIND="metadata"
    ;;
  *)
    echo "ERROR: invalid --section ${SECTION}. Must be one of: exec-prose, exec-strengths, exec-critical, metadata.<field>" >&2
    exit 2
    ;;
esac

# --- Build the value to assign (passed as $val to jq) ----------------------
NEW_TMP=$(mktemp)
trap 'rm -f "$NEW_TMP"' EXIT

LOCK_FILE="${REPORT_JSON}.lock"
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  flock -w 10 200 || { echo "ERROR: could not acquire lock on ${LOCK_FILE} within 10s" >&2; exit 1; }
fi

case "$VALUE_KIND" in
  string)
    if [ "$JSON_SET" -eq 1 ]; then
      echo "ERROR: --section ${SECTION} expects --text or --text-file, not --json" >&2
      exit 1
    fi
    jq --arg val "$TEXT" "${JQ_PATH} = \$val" "$REPORT_JSON" > "$NEW_TMP"
    ;;
  string-list)
    if [ "$JSON_SET" -eq 1 ]; then
      # Expect a JSON array of strings.
      if ! echo "$JSON_VALUE" | jq -e 'type == "array" and (all(.[]; type == "string"))' >/dev/null 2>&1; then
        echo "ERROR: --json for ${SECTION} must be a JSON array of strings" >&2
        exit 1
      fi
      jq --argjson val "$JSON_VALUE" "${JQ_PATH} = \$val" "$REPORT_JSON" > "$NEW_TMP"
    else
      # One item per non-blank line; trim leading whitespace; skip blanks.
      LIST_JSON=$(printf '%s\n' "$TEXT" \
        | awk 'NF { sub(/^[[:space:]]+/, ""); print }' \
        | jq -R -s 'split("\n") | map(select(length > 0))')
      jq --argjson val "$LIST_JSON" "${JQ_PATH} = \$val" "$REPORT_JSON" > "$NEW_TMP"
    fi
    ;;
  metadata)
    if [ "$JSON_SET" -eq 1 ]; then
      if ! echo "$JSON_VALUE" | jq -e . >/dev/null 2>&1; then
        echo "ERROR: --json is not valid JSON" >&2
        exit 1
      fi
      jq --argjson val "$JSON_VALUE" "${JQ_PATH} = \$val" "$REPORT_JSON" > "$NEW_TMP"
    else
      jq --arg val "$TEXT" "${JQ_PATH} = \$val" "$REPORT_JSON" > "$NEW_TMP"
    fi
    ;;
esac

if ! jq -e . "$NEW_TMP" >/dev/null 2>&1; then
  echo "ERROR: jq update produced invalid JSON; aborting" >&2
  exit 3
fi

mv "$NEW_TMP" "$REPORT_JSON"
trap - EXIT

# Run validate-report; coverage may be incomplete mid-review (rc=3) which is
# fine here. Per-record failure (rc=2) means we corrupted the file — exit 3.
PV=$(mktemp)
if "${SCRIPT_DIR}/validate-report.sh" --data-dir "$DATA_DIR" --quiet 2>"$PV"; then
  rm -f "$PV"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "ERROR: post-update validation failed:" >&2
    cat "$PV" >&2
    rm -f "$PV"
    exit 3
  fi
  rm -f "$PV"
fi

log_info "set-narrative: ${SECTION} updated in ${REPORT_JSON}"
exit 0
