#!/usr/bin/env bash
# validate-report.sh — verify ${DATA_DIR}/report.json against the schema and
# the Check Registry. This is the safety net for the structured report flow:
# every other helper that mutates report.json calls this before declaring
# success, and generate-report.sh refuses to render unless validation passes.
#
# Validations:
#   1. report.json is valid JSON
#   2. Top-level shape (metadata / executive_summary / findings)
#   3. metadata.frameworks ⊆ {WA, NIST, FinOps}
#   4. metadata.review_scope ∈ {Code Review, Cloud Review, Full Review}
#   5. Every finding has a registered check_id (looked up in
#      references/check-registry.json)
#   6. status / method / source / maturity values are within their closed sets
#   7. Required narrative fields are present per status
#   8. Coverage: every check_id in the registry filtered by
#      metadata.frameworks appears in findings[] exactly once. Computed
#      dynamically from registry × frameworks; no hard-coded totals.
#
# Usage:
#   validate-report.sh --data-dir <dir> [--quiet]
#
# Exit codes:
#   0  valid
#   1  argument or path error
#   2  schema / closed-set / narrative validation failure
#   3  coverage failure (missing, duplicate, or unregistered check_ids)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  validate-report.sh --data-dir <dir> [--quiet]

Required:
  --data-dir <dir>  Review data directory (must contain report.json)

Optional:
  --quiet           Suppress success log; errors still print on failure.

Exit codes:
  0  valid
  1  argument or path error
  2  schema / closed-set / narrative validation failure
  3  coverage failure (missing, duplicate, or unregistered check_ids)
USAGE_EOF
}

DATA_DIR=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)   DATA_DIR="${2:-}"; shift 2 ;;
    --data-dir=*) DATA_DIR="${1#--data-dir=}"; shift ;;
    --quiet)      QUIET=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
  esac
done

if [ -z "$DATA_DIR" ]; then
  echo "ERROR: --data-dir is required" >&2
  usage >&2
  exit 1
fi
if [ ! -d "$DATA_DIR" ]; then
  echo "ERROR: data directory not found: ${DATA_DIR}" >&2
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

# Step 1: valid JSON.
if ! jq empty "$REPORT_JSON" 2>/dev/null; then
  echo "ERROR: report.json is not valid JSON" >&2
  exit 2
fi

# All structural and per-finding checks happen in one jq invocation. The
# program emits a JSON object with arrays of human-readable error strings,
# grouped by category. Coverage is then computed in a second jq pass.
ERR_JSON=$(jq -n \
  --slurpfile r "$REPORT_JSON" \
  --slurpfile reg "$REGISTRY_FILE" '
def closed_status: ["PASS","FAIL","PARTIAL","N/A","PENDING"];
def closed_method: ["auto","code","interactive","cross-ref","needs-input"];
def closed_maturity: ["Crawl","Walk","Run"];
def closed_frameworks: ["WA","NIST","FinOps"];
def closed_scope: ["Code Review","Cloud Review","Full Review"];

# Filename component allowed by --source dynamic:<filename>.
def source_ok($s):
  if (($s | type) != "string") then false
  elif ($s | startswith("dynamic:") | not) then false
  else
    ($s | sub("^dynamic:"; "")) as $name
    | ($name | length) > 0 and ($name | test("^[A-Za-z0-9._-]+$"))
  end;

. as $root
| ($r[0]) as $rep
| ($reg[0].checks) as $regChecks
| ($regChecks | map(.check_id)) as $regIds
| ($regChecks | map(select(.requires_user_input == true) | .check_id)) as $manualIds
| ($rep.metadata // {}) as $md
| ($rep.findings // []) as $findings

# ------------------------------------------------------------------ shape
| ((["metadata","executive_summary","findings"]
    | map(select(. as $k | ($rep | has($k)) | not)) | map("missing top-level: \(.)"))
    + (if ($rep.findings | type) != "array" then ["findings is not an array"] else [] end)
   ) as $shape

# ------------------------------------------------------------------ metadata
| ((if ($md.frameworks | type) != "array" then ["metadata.frameworks must be an array"] else
      ($md.frameworks | map(select((. as $x | closed_frameworks | index($x)) | not))
        | map("metadata.frameworks contains invalid value: \(.)"))
      + (if ($md.frameworks | length) == 0 then ["metadata.frameworks is empty"] else [] end)
    end)
    + (if ($md.review_scope // "") | (. as $x | closed_scope | index($x)) | not
        then ["metadata.review_scope invalid: \($md.review_scope // null)"]
        else [] end)
   ) as $metaErr

# ------------------------------------------------------------------ findings
| [ $findings
    | to_entries[]
    | .key as $i
    | .value as $f
    | (if ($f.check_id // "") == "" then "findings[\($i)]: missing check_id" else empty end),
      (if ($f.check_id // "") != "" and (($regIds | index($f.check_id)) | not)
         then "findings[\($i)]: check_id \($f.check_id) is not in the registry"
         else empty end),
      (if ($f.status // "") | (. as $x | closed_status | index($x)) | not
         then "findings[\($i)] (\($f.check_id // "?")): invalid status \($f.status // "")"
         else empty end),
      (if ($f.method // null) != null
         and (($f.method | (. as $x | closed_method | index($x))) | not)
         then "findings[\($i)] (\($f.check_id // "?")): invalid method \($f.method)"
         else empty end),
      (if ($f.maturity // null) != null
         and (($f.maturity | (. as $x | closed_maturity | index($x))) | not)
         then "findings[\($i)] (\($f.check_id // "?")): invalid maturity \($f.maturity)"
         else empty end),
      (if ($f.source // null) != null and (source_ok($f.source) | not)
         then "findings[\($i)] (\($f.check_id // "?")): invalid source \($f.source) (only dynamic:<filename> with [A-Za-z0-9._-]+ allowed)"
         else empty end),
      # Required-narrative-per-status
      (if ($f.status == "PASS") and (($f.finding // "") == "")
         then "findings[\($i)] (\($f.check_id // "?")): PASS requires finding" else empty end),
      (if ($f.status == "FAIL" or $f.status == "PARTIAL") and (($f.finding // "") == "")
         then "findings[\($i)] (\($f.check_id // "?")): \($f.status) requires finding" else empty end),
      (if ($f.status == "FAIL" or $f.status == "PARTIAL") and (($f.remediation // "") == "")
         then "findings[\($i)] (\($f.check_id // "?")): \($f.status) requires remediation" else empty end),
      (if ($f.status == "PENDING") and (($f.question // "") == "")
         then "findings[\($i)] (\($f.check_id // "?")): PENDING requires question" else empty end),
      (if ($f.status == "N/A") and (($f.reason // "") == "")
         then "findings[\($i)] (\($f.check_id // "?")): N/A requires reason" else empty end),
      # Manual-input guard: a check flagged requires_user_input in the registry
      # can only leave PENDING when a human actually answered (method
      # "interactive") or a WA finding already covered it (method "cross-ref").
      # Any other method with a non-PENDING status means the check was resolved
      # without the required user input — the exact failure this guard prevents.
      (if (($f.check_id // "") != "") and (($manualIds | index($f.check_id)))
          and (($f.status // "") != "PENDING")
          and (([ "interactive", "cross-ref" ] | index($f.method // "needs-input")) | not)
         then "findings[\($i)] (\($f.check_id)): check requires user input — a non-PENDING status (\($f.status)) is only allowed with method interactive (user answered) or cross-ref (covered by a WA finding); got method \($f.method // "needs-input"). Mark PENDING if no answer was collected."
         else empty end)
  ] as $perFinding

| {shape: $shape, metadata: $metaErr, findings: $perFinding}
')

# Aggregate any errors from the structured object.
ERR_LINES=$(echo "$ERR_JSON" | jq -r '
  [ .shape[]?, .metadata[]?, .findings[]? ]
  | .[]
')

if [ -n "$ERR_LINES" ]; then
  echo "ERROR: report.json validation failed:" >&2
  # shellcheck disable=SC2001 # sed is clearer than ${var//search/replace}
  # for multi-line indentation of an entire error block
  echo "$ERR_LINES" | sed 's/^/  - /' >&2
  exit 2
fi

# Step 8a: executive summary prose paragraph check (non-blocking).
PROSE_CONTENT=$(jq -r '.executive_summary.prose // ""' "$REPORT_JSON")
if [ -n "$PROSE_CONTENT" ]; then
  PROSE_LINE_COUNT=$(printf '%s' "$PROSE_CONTENT" | wc -l | tr -d ' ')
  if [ "$PROSE_LINE_COUNT" -eq 0 ]; then
    printf '%s\n' "WARNING: executive_summary.prose has no newlines — all 3 paragraphs are on one line. Re-run set-narrative.sh --section exec-prose --text-file with \\n\\n paragraph separators." >&2
  else
    PROSE_BLANK_LINES=$(printf '%s' "$PROSE_CONTENT" | grep -c '^$' || true)
    if [ "$PROSE_BLANK_LINES" -lt 2 ]; then
      echo "WARNING: executive_summary.prose has $((PROSE_BLANK_LINES + 1)) paragraph(s); expected 3 (separated by blank lines)." >&2
    fi
  fi
fi

# Step 8: coverage check. Dynamic — compute expected set from registry filtered
# by the active frameworks, then diff against findings[] check_ids.
COV_JSON=$(jq -n \
  --slurpfile r "$REPORT_JSON" \
  --slurpfile reg "$REGISTRY_FILE" '
. as $root
| ($r[0]) as $rep
| ($rep.metadata.frameworks // []) as $fw
| ($reg[0].checks
    | map(select(.frameworks as $cf | any($cf[]; . as $x | $fw | index($x))))
    | map(.check_id) | unique) as $expected
| ($rep.findings | map(.check_id // "")) as $observedAll
| ($observedAll | unique) as $observedUnique
| (($observedAll | length) - ($observedUnique | length)) as $duplicates
| ($expected - $observedUnique) as $missing
| ($observedUnique - $expected) as $extra
| ($observedAll
    | reduce .[] as $id ({}; .[$id] += 1)
    | to_entries
    | map(select(.value > 1))
    | map(.key)) as $dup_ids
| {
    expected_count: ($expected | length),
    observed_count: ($observedAll | length),
    duplicate_count: $duplicates,
    duplicate_ids: $dup_ids,
    missing: $missing,
    extra: $extra
  }
')

EXPECTED=$(echo "$COV_JSON" | jq -r '.expected_count')
OBSERVED=$(echo "$COV_JSON" | jq -r '.observed_count')
DUP_COUNT=$(echo "$COV_JSON" | jq -r '.duplicate_count')
MISSING_COUNT=$(echo "$COV_JSON" | jq -r '.missing | length')
EXTRA_COUNT=$(echo "$COV_JSON" | jq -r '.extra | length')

if [ "$DUP_COUNT" -gt 0 ] || [ "$MISSING_COUNT" -gt 0 ] || [ "$EXTRA_COUNT" -gt 0 ]; then
  # Disable the ERR trap before printing details and exiting. Some of the
  # subsequent jq | sed pipelines can return non-zero on empty input under
  # set -E, which would surface a confusing "FATAL" line to the caller even
  # though this is a deliberate, well-formed exit (rc=3).
  trap - ERR
  echo "ERROR: coverage check failed (frameworks=$(jq -rc '.metadata.frameworks' "$REPORT_JSON"))" >&2
  echo "  expected ${EXPECTED} check(s) from registry; found ${OBSERVED} in report.json" >&2
  if [ "$DUP_COUNT" -gt 0 ]; then
    echo "  duplicate check_id(s):" >&2
    echo "$COV_JSON" | jq -r '.duplicate_ids[]' | sed 's/^/    - /' >&2
  fi
  if [ "$MISSING_COUNT" -gt 0 ]; then
    echo "  missing check_id(s):" >&2
    echo "$COV_JSON" | jq -r '.missing[]' | sed 's/^/    - /' >&2
  fi
  if [ "$EXTRA_COUNT" -gt 0 ]; then
    echo "  unregistered or out-of-framework check_id(s):" >&2
    echo "$COV_JSON" | jq -r '.extra[]' | sed 's/^/    - /' >&2
  fi
  exit 3
fi

# --- Step -> child derivation verification (R4.10, R4.1) -------------------
# Verify the deterministic step -> child rollup for every finding that carries a
# non-empty steps[] array. Two integrity checks, both exit 2 (the same contract
# as the parent-rollup check below):
#   1. Every steps[].status is within the closed 5-value set
#      {PASS,FAIL,PARTIAL,N/A,PENDING}. A per-step status outside the set is an
#      integrity failure.
#   2. derive_child_status(steps[]) (the canonical deriver in _common.sh) equals
#      the stored finding status. A mismatch is an integrity failure.
# Runs AFTER the coverage check (exit 3) and BEFORE the parent-rollup integrity
# check (exit 2): per the three-tier pipeline (steps -> child -> parent),
# children are verified before the parent rollups that consume them.

# (1) Closed-set check over every per-step status, collected in one jq pass so a
# single invalid value anywhere in any steps[] is reported.
STEP_STATUS_VIOLATIONS=$(jq -r '
  def closed_status: ["PASS","FAIL","PARTIAL","N/A","PENDING"];
  (.findings // [])
  | to_entries[]
  | .key as $i
  | .value as $f
  | (($f.steps // []) | to_entries[]
     | select((.value.status // null) as $s | (closed_status | index($s)) | not)
     | "findings[\($i)] (\($f.check_id // "?")): step index \(.key) has invalid status \(.value.status // "<absent>") (allowed: PASS/FAIL/PARTIAL/N/A/PENDING)")
' "$REPORT_JSON")

if [ -n "$STEP_STATUS_VIOLATIONS" ]; then
  # Disable the ERR trap before the deliberate non-zero exit; the jq | sed
  # pipeline below can return non-zero on empty input under set -E, which would
  # surface a confusing FATAL line even though this is a well-formed exit (rc=2).
  trap - ERR
  echo "ERROR: step status closed-set check failed (a steps[].status is outside PASS/FAIL/PARTIAL/N/A/PENDING):" >&2
  # shellcheck disable=SC2001 # sed is clearer than ${var//search/replace}
  # for multi-line indentation of an entire error block
  echo "$STEP_STATUS_VIOLATIONS" | sed 's/^/  - /' >&2
  exit 2
fi

# (2) Derivation comparison: recompute derive_child_status per step-bearing
# finding (steps[] passed positionally) and assert it equals the stored finding
# status. Calling the canonical deriver keeps a single source of truth rather
# than reimplementing the derivation here.
STEP_BEARING_IDX=$(jq -r '
  (.findings // [])
  | to_entries[]
  | select(((.value.steps // []) | length) > 0)
  | .key' "$REPORT_JSON")

for __idx in $STEP_BEARING_IDX; do
  __steps_json=$(jq -c ".findings[${__idx}].steps" "$REPORT_JSON")
  __stored=$(jq -r ".findings[${__idx}].status // \"\"" "$REPORT_JSON")
  __check_id=$(jq -r ".findings[${__idx}].check_id // \"?\"" "$REPORT_JSON")
  __derived=$(derive_child_status "$__steps_json")
  if [ "$__stored" != "$__derived" ]; then
    # Deliberate integrity exit — drop the ERR trap so no FATAL line is printed.
    trap - ERR
    echo "ERROR: step-derivation integrity check failed (stored status does not match derive_child_status from steps[]):" >&2
    echo "  - ${__check_id} (findings[${__idx}]): stored=${__stored} derived=${__derived}" >&2
    exit 2
  fi
done

# --- Parent-rollup integrity verification (R1.2, R1.11, R1.12) -------------
# Recompute parent_rollups from the current findings[] + lenses and compare the
# {question_id, risk, status} triples against the stored report.json
# parent_rollups. Any missing, extra, or mismatched triple is an integrity
# failure (exit 2), which keeps merge-findings.sh's rollback-on-rc==2 contract
# (the 0/1/2/3 exit-code contract is preserved: 2 = schema/integrity).
# Runs AFTER the coverage check and BEFORE the final OK/exit 0.
#
# Graceful handling of older reports: `.parent_rollups // []` defaults an
# absent/null field to []. If there are no WA findings, the recomputed WA set is
# also empty, so absent rollups match (skip). If findings exist that derive
# non-empty rollups, an absent/empty stored set fails the comparison as a
# missing triple — exactly the intended mismatch.
FRESH_ROLLUPS=$(recompute_parent_rollups "$REPORT_JSON" \
  "${SKILL_ROOT}/references/generative-ai-lens.json" \
  "${SKILL_ROOT}/references/nist-ai-rmf-lens.json" \
  "${SKILL_ROOT}/references/finops-ai-lens.json")

ROLLUP_DIFF=$(jq -n \
  --argjson fresh "$FRESH_ROLLUPS" \
  --slurpfile r "$REPORT_JSON" '
  def triples: map({question_id, risk, status}) | sort_by(.question_id);
  ($r[0].parent_rollups // []) as $stored
  | { missing: (($fresh | triples) - ($stored | triples)),
      extra:   (($stored | triples) - ($fresh | triples)) }
')
ROLLUP_MISSING=$(echo "$ROLLUP_DIFF" | jq '.missing | length')
ROLLUP_EXTRA=$(echo "$ROLLUP_DIFF" | jq '.extra | length')
if [ "$ROLLUP_MISSING" -gt 0 ] || [ "$ROLLUP_EXTRA" -gt 0 ]; then
  # Disable the ERR trap before printing details and exiting; the jq pipelines
  # below can return non-zero on empty input under set -E, which would surface a
  # confusing FATAL line even though this is a deliberate exit (rc=2).
  trap - ERR
  echo "ERROR: parent_rollups integrity check failed (stored rollups do not match derivation from findings[]):" >&2
  echo "$ROLLUP_DIFF" | jq -r '.missing[]? | "  - missing/mismatched: \(.question_id) risk=\(.risk) status=\(.status)"' >&2
  echo "$ROLLUP_DIFF" | jq -r '.extra[]? | "  - stale/extra: \(.question_id) risk=\(.risk) status=\(.status)"' >&2
  exit 2
fi

if [ "$QUIET" -ne 1 ]; then
  log_info "validate-report: OK (${OBSERVED}/${EXPECTED} checks, frameworks=$(jq -rc '.metadata.frameworks' "$REPORT_JSON"))"
fi
exit 0
