#!/usr/bin/env bash
# draft-narrative.sh — generate first-draft narrative content from
# report.json and manifest.json. Writes two files under
# $DATA_DIR/_work/drafts/:
#
#   exec-critical.txt   — top FAIL/PARTIAL findings by severity
#   exec-strengths.txt  — PASS findings (one per line, summarized)
#
# The agent should review and edit these drafts before piping them through
# set-narrative.sh --text-file.
#
# Usage:
#   draft-narrative.sh --data-dir <path>
#
# Exit codes:
#   0  drafts written
#   1  argument or path error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
    cat <<'USAGE_EOF'
Usage:
  draft-narrative.sh --data-dir <path>

Required:
  --data-dir <path>   Review data directory containing report.json.

Output:
  Two files under <data-dir>/_work/drafts/:
    - exec-critical.txt
    - exec-strengths.txt
USAGE_EOF
}

DATA_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir)   DATA_DIR="${2:-}"; shift 2 ;;
        --data-dir=*) DATA_DIR="${1#--data-dir=}"; shift ;;
        --help|-h)    usage; exit 0 ;;
        *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
    esac
done

if [ -z "$DATA_DIR" ]; then
    echo "ERROR: --data-dir is required" >&2
    usage >&2
    exit 1
fi
REPORT_JSON="${DATA_DIR}/report.json"
if [ ! -f "$REPORT_JSON" ]; then
    echo "ERROR: report.json not found: ${REPORT_JSON}" >&2
    exit 1
fi

SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_FILE="${SKILL_ROOT}/references/check-registry.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "ERROR: registry not found: ${REGISTRY_FILE}" >&2
    exit 1
fi

DRAFTS_DIR=$(work_dir "$DATA_DIR" drafts)

# ---------------------------------------------------------------------------
# Critical/High findings
# ---------------------------------------------------------------------------
# Severity comes from the registry. Titles come from the lens index (canonical
# source of every check's title). Order: HIGH > MEDIUM > LOW. We surface only
# HIGH and MEDIUM here so the executive summary stays focused; the agent can
# promote LOWs into the prose if they want.
LENS_INDEX_TMP=$(mktemp)
load_lens_index > "$LENS_INDEX_TMP"

jq -r --slurpfile reg "$REGISTRY_FILE" --slurpfile lens "$LENS_INDEX_TMP" '
    ($reg[0].checks
        | reduce .[] as $c ({}; .[$c.check_id] = {severity: $c.severity})
    ) as $reg_map
    | ($lens[0]
        | reduce .[] as $l ({}; .[$l.check_id] = $l.title)
    ) as $title_map
    | .findings
    | map(select(.status == "FAIL" or .status == "PARTIAL"))
    | map(. + {severity: ($reg_map[.check_id].severity // "MEDIUM"),
               title:    ($title_map[.check_id]      // .check_id)})
    | sort_by(
        if .severity == "HIGH" then 0
        elif .severity == "MEDIUM" then 1
        else 2 end,
        .check_id)
    | .[]
    | "[\(.severity)] \(.check_id) — \(.title): \( (.finding // "") | gsub("\n"; " ") | .[0:200] )"
' "$REPORT_JSON" > "${DRAFTS_DIR}/exec-critical.txt"

CRIT_LINES=$(wc -l < "${DRAFTS_DIR}/exec-critical.txt" | tr -d ' ')
log_info "draft-narrative: wrote ${CRIT_LINES} critical/high line(s) to ${DRAFTS_DIR}/exec-critical.txt"

# ---------------------------------------------------------------------------
# Strengths (PASS findings)
# ---------------------------------------------------------------------------
jq -r --slurpfile lens "$LENS_INDEX_TMP" '
    ($lens[0]
        | reduce .[] as $l ({}; .[$l.check_id] = $l.title)
    ) as $title_map
    | .findings
    | map(select(.status == "PASS"))
    | sort_by(.check_id)
    | .[]
    | "\($title_map[.check_id] // .check_id): \( (.finding // "") | gsub("\n"; " ") | .[0:160] ) (\(.check_id))"
' "$REPORT_JSON" > "${DRAFTS_DIR}/exec-strengths.txt"

rm -f "$LENS_INDEX_TMP"

STRENGTH_LINES=$(wc -l < "${DRAFTS_DIR}/exec-strengths.txt" | tr -d ' ')
log_info "draft-narrative: wrote ${STRENGTH_LINES} strength line(s) to ${DRAFTS_DIR}/exec-strengths.txt"

# Summary to stdout so the orchestrator knows what was produced.
echo "drafts:"
echo "  exec-critical:  ${DRAFTS_DIR}/exec-critical.txt (${CRIT_LINES} lines)"
echo "  exec-strengths: ${DRAFTS_DIR}/exec-strengths.txt (${STRENGTH_LINES} lines)"

exit 0
