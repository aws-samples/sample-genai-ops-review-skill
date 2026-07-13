#!/usr/bin/env bash
# build-findings-skeleton.sh — emit a JSONL findings skeleton for one or more
# owners (sub-skills), pre-populated with canonical question text from the
# bundled YAML/registry references. The agent edits only the deltas (status
# overrides, finding/remediation/reason text) and feeds the file straight
# into merge-findings.sh.
#
# Owner names match references/owned-checks.json keys, e.g.:
#   WA:Security, WA:Ops Excellence, WA:Reliability, WA:Performance,
#   WA:Cost, WA:Sustainability, WA:Responsible AI, WA:Agentic,
#   WA:AgentCore, WA:Lifecycle,
#   NIST:Govern, NIST:Map, NIST:Measure, NIST:Manage,
#   FinOps:Understand, FinOps:Quantify Business Value,
#   FinOps:Optimize, FinOps:Manage
#
# For each owned check_id the helper emits one JSON object per line with:
#   - check_id          (always)
#   - status            "PENDING" by default
#   - method            "needs-input" by default (matches PENDING)
#   - question          canonical text from the framework YAML (NIST/FinOps)
#                       or from references/<pillar>-checks.md when present
#   - why_it_matters    omitted (agent fills if it wants)
#   - maturity          for FinOps only, taken from finops-ai-checks.yaml
#   - doc_url           for NIST/FinOps only, taken from the YAML
#   - severity          NOT included in the JSONL (registry tracks it; the
#                       renderer pulls it directly when emitting findings)
#
# WA pillar checks (e.g., GENSEC02_BP01) do not have an `interactive_question`
# in machine-readable form today, so for those the helper emits a placeholder
# question synthesized from the registry title. Agents are expected to
# override these when the check can be auto-assessed from the per-pillar
# summary JSON.
#
# Usage:
#   build-findings-skeleton.sh --owner "<owner>" [--owner "<owner>" ...]
#                              [--data-dir <path>] [--default-status PENDING]
#                              [--output <file>]
#
# Without --output the helper writes JSONL to stdout. --data-dir is read so
# future iterations can pre-fill answers from manifest/summary JSON, but it
# is not strictly required today.
#
# Exit codes:
#   0  skeleton written
#   1  argument or path error
#   2  owner not found in references/owned-checks.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
    cat <<'USAGE_EOF'
Usage:
  build-findings-skeleton.sh --owner "<owner>" [--owner "<owner>" ...]
                             [--data-dir <path>]
                             [--default-status <status>]
                             [--output <file>]

Required:
  --owner <name>          Owner from references/owned-checks.json. May be
                          repeated to combine multiple owners (typical for
                          NIST and FinOps which split across 4 owners).

Optional:
  --data-dir <path>       Review data directory (used in future for pre-
                          filling answers; accepted today for symmetry).
  --default-status <s>    Status to apply to every emitted line. Default:
                          PENDING. Closed set: PENDING | PASS | FAIL |
                          PARTIAL | N/A. Non-PENDING outputs may need
                          additional fields the agent must fill in before
                          merge-findings.sh accepts them.
  --output <file>         Write JSONL to <file> instead of stdout.

Exit codes:
  0  skeleton written
  1  argument or path error
  2  owner not found
USAGE_EOF
}

OWNERS=()
# shellcheck disable=SC2034 # accepted today for CLI symmetry / future use
# (see header comment); not yet read by this script's logic.
DATA_DIR=""
OUTPUT=""
DEFAULT_STATUS="PENDING"

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)            OWNERS+=("${2:-}"); shift 2 ;;
        --owner=*)          OWNERS+=("${1#--owner=}"); shift ;;
        --data-dir)         DATA_DIR="${2:-}"; shift 2 ;;
        --data-dir=*)       DATA_DIR="${1#--data-dir=}"; shift ;;
        --output)           OUTPUT="${2:-}"; shift 2 ;;
        --output=*)         OUTPUT="${1#--output=}"; shift ;;
        --default-status)   DEFAULT_STATUS="${2:-}"; shift 2 ;;
        --default-status=*) DEFAULT_STATUS="${1#--default-status=}"; shift ;;
        --help|-h)          usage; exit 0 ;;
        *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
    esac
done

if [ "${#OWNERS[@]}" -eq 0 ]; then
    echo "ERROR: at least one --owner is required" >&2
    usage >&2
    exit 1
fi

case "$DEFAULT_STATUS" in
    PASS|FAIL|PARTIAL|N/A|PENDING) ;;
    *) echo "ERROR: --default-status must be one of PASS|FAIL|PARTIAL|N/A|PENDING (got '${DEFAULT_STATUS}')" >&2; exit 1 ;;
esac

SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OWNED_FILE="${SKILL_ROOT}/references/owned-checks.json"
REGISTRY_FILE="${SKILL_ROOT}/references/check-registry.json"
FINOPS_YAML="${SKILL_ROOT}/references/finops-ai-checks.yaml"

for f in "$OWNED_FILE" "$REGISTRY_FILE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required reference file not found: ${f}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Resolve all check_ids owned by the supplied owners.
# ---------------------------------------------------------------------------
OWNERS_JSON=$(printf '%s\n' "${OWNERS[@]}" | jq -R . | jq -s .)
CHECK_IDS=$(jq -r --argjson owners "$OWNERS_JSON" '
    .owners | to_entries[]
    | select(.key as $k | $owners | index($k))
    | .value.ids[]
' "$OWNED_FILE" | awk '!seen[$0]++')

if [ -z "$CHECK_IDS" ]; then
    echo "ERROR: no check_ids resolved for owners: ${OWNERS[*]}" >&2
    echo "       valid owners are: $(jq -r '.owners | keys | join(", ")' "$OWNED_FILE")" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Lens-derived lookups for canonical question text, doc URL, and severity.
# The four lens JSON files (loaded by load_lens_index in _common.sh) are now
# the single source of truth for every check's wording. NIST and FinOps lenses
# are generated from their YAMLs by build-lenses.sh and carry the canonical
# question, description, and documentation URL per check. WA core BPs carry
# an informative title and a documentation URL.
# ---------------------------------------------------------------------------
LENS_INDEX_JSON=$(load_lens_index)

# Frameworks per check_id and severity per check_id come from the registry
# (it is the canonical source for those structural attributes). Title /
# question text / doc URL come from the lens.
REGISTRY_FRAMEWORK_TSV=$(jq -r '.checks[] | "\(.check_id)\t\(.severity)\t\(.frameworks | join(","))"' "$REGISTRY_FILE")

registry_frameworks() {
    printf '%s\n' "$REGISTRY_FRAMEWORK_TSV" | awk -F'\t' -v id="$1" '$1==id { print $3; exit }'
}

# Lens lookup helpers — extract the title/url/improvement_text via jq once
# per call (small enough that a per-id jq invocation is cheap given <200
# checks).
lens_field() {
    local id="$1" field="$2"
    printf '%s' "$LENS_INDEX_JSON" \
      | jq -r --arg id "$id" --arg f "$field" '
          ([ .[] | select(.check_id == $id) ][0] // {}) | .[$f] // ""
        '
}

# ---------------------------------------------------------------------------
# Emit JSONL.
# ---------------------------------------------------------------------------
emit_lines() {
    local id title q doc mat
    while IFS= read -r id; do
        [ -z "$id" ] && continue

        # Lens-canonical fields. The lens index already carries the right
        # text for every framework; we no longer maintain a separate
        # YAML-parsing path here.
        title=$(lens_field "$id" "title")
        q=$(lens_field "$id" "question_title")
        # Fall back: if the lens question_title is empty (rare), use title.
        [ -z "$q" ] && q="$title"
        doc=$(lens_field "$id" "url")

        # Maturity is FinOps-only — pulled from the FinOps YAML by
        # build-lenses.sh. The lens does not currently carry it on the
        # choice, so re-read directly from the FinOps YAML when the check
        # is owned by FinOps.
        local frameworks; frameworks=$(registry_frameworks "$id")
        mat=""
        case ",${frameworks}," in
            *,FinOps,*)
                mat=$(awk -v id="$id" '
                    BEGIN { found=0 }
                    $0 ~ "^[[:space:]]*-[[:space:]]+id:[[:space:]]*\"?" id "\"?[[:space:]]*$" { found=1 }
                    found && /^[[:space:]]+maturity:/ {
                        line=$0; sub(/^[[:space:]]+maturity:[[:space:]]*/, "", line)
                        sub(/^[ \t]*"/, "", line); sub(/"[ \t]*$/, "", line)
                        print line; exit
                    }
                    /^[[:space:]]*-[[:space:]]+id:/ && !($0 ~ "^[[:space:]]*-[[:space:]]+id:[[:space:]]*\"?" id "\"?[[:space:]]*$") { found=0 }
                ' "$FINOPS_YAML" 2>/dev/null || echo "")
                ;;
        esac

        # Build the JSON object. Status drives which fields are required by
        # merge-findings.sh; the helper writes the minimum and lets the agent
        # add finding/remediation/reason text when it changes status.
        local obj
        case "$DEFAULT_STATUS" in
            PENDING)
                obj=$(jq -nc \
                    --arg cid "$id" \
                    --arg s   "PENDING" \
                    --arg m   "needs-input" \
                    --arg q   "$q" \
                    --arg doc "$doc" \
                    --arg mat "$mat" \
                    '
                    { check_id: $cid, status: $s, method: $m, question: $q }
                    + (if $doc == "" then {} else { doc_url: $doc } end)
                    + (if $mat == "" then {} else { maturity: $mat } end)
                    ')
                ;;
            PASS)
                obj=$(jq -nc --arg cid "$id" \
                    '{ check_id: $cid, status: "PASS", finding: "TODO: PASS evidence" }')
                ;;
            FAIL|PARTIAL)
                obj=$(jq -nc --arg cid "$id" --arg s "$DEFAULT_STATUS" --arg doc "$doc" --arg mat "$mat" '
                    { check_id: $cid, status: $s, finding: "TODO: finding", remediation: "TODO: remediation" }
                    + (if $doc == "" then {} else { doc_url: $doc } end)
                    + (if $mat == "" then {} else { maturity: $mat } end)
                    ')
                ;;
            "N/A")
                obj=$(jq -nc --arg cid "$id" \
                    '{ check_id: $cid, status: "N/A", reason: "TODO: not applicable reason" }')
                ;;
        esac

        printf '%s\n' "$obj"
    done <<< "$CHECK_IDS"
}

if [ -n "$OUTPUT" ]; then
    out_dir=$(dirname "$OUTPUT")
    [ -d "$out_dir" ] || mkdir -p "$out_dir"
    emit_lines > "$OUTPUT"
    log_info "build-findings-skeleton: wrote $(wc -l < "$OUTPUT" | tr -d ' ') line(s) to ${OUTPUT}"
else
    emit_lines
fi
exit 0
