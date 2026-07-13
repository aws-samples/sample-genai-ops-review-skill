#!/usr/bin/env bash
# merge-findings.sh — atomically merge a batch of findings into report.json.
#
# Each input record is a JSON object matching the `findings[]` schema in
# references/report-schema.md. Input format is JSON Lines (one object per
# non-empty, non-comment line). Records can be supplied via --input <file>
# or piped on stdin.
#
# Behavior:
#   - Validates the entire batch first (closed sets, required narrative per
#     status, registered check_ids). If any record is invalid, no change is
#     made to report.json.
#   - Defaults --method to needs-input for PENDING and auto otherwise so
#     callers don't have to repeat the rule the helper already enforces.
#   - Merges into findings[] under an exclusive flock on report.json. By
#     default, duplicate check_ids in the existing report.json are an error
#     (refuses to silently overwrite). --replace updates existing entries
#     in place.
#   - Calls validate-report.sh with --quiet at the end. If the resulting
#     report.json fails validation, the merge is rolled back.
#
# Usage:
#   merge-findings.sh --data-dir <dir> [--input <file.jsonl>] [--replace]
#
# Exit codes:
#   0  batch merged successfully
#   1  argument or path error
#   2  per-record validation failure (closed set / required field / registry)
#   3  duplicate check_id without --replace
#   4  post-merge validate-report.sh failed (rollback performed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  merge-findings.sh --data-dir <dir> [--input <file.jsonl>] [--replace]

Required:
  --data-dir <dir>   Review data directory (must contain report.json).

Optional:
  --input <file>     JSONL file with one finding per line.
                     If omitted, reads JSONL from stdin.
  --replace          If a check_id already exists in report.json, replace it
                     in place. Without --replace, duplicates exit non-zero.
  --partial          Skip the post-merge validate-report.sh step. Use for
                     intermediate batches when the full report does not yet
                     contain every active-framework check_id. The agent or
                     orchestrator should run validate-report.sh once after
                     all batches have been merged.

Closed sets and required fields per status are documented in
references/report-schema.md and SKILL.md → "Helper Closed Sets".

Exit codes:
  0  batch merged successfully
  1  argument or path error
  2  per-record validation failure
  3  duplicate check_id without --replace
  4  post-merge validate-report.sh failed (rollback performed)
USAGE_EOF
}

DATA_DIR=""
INPUT=""
REPLACE=0
PARTIAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)   DATA_DIR="${2:-}"; shift 2 ;;
    --data-dir=*) DATA_DIR="${1#--data-dir=}"; shift ;;
    --input)      INPUT="${2:-}"; shift 2 ;;
    --input=*)    INPUT="${1#--input=}"; shift ;;
    --replace)    REPLACE=1; shift ;;
    --partial)    PARTIAL=1; shift ;;
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

# --- Read input into a JSON array (BATCH_JSON) -----------------------------
BATCH_TMP=$(mktemp)
trap 'rm -f "$BATCH_TMP"' EXIT

if [ -n "$INPUT" ]; then
  if [ ! -f "$INPUT" ]; then
    echo "ERROR: --input file not found: ${INPUT}" >&2
    exit 1
  fi
  cp "$INPUT" "$BATCH_TMP"
else
  cat > "$BATCH_TMP"
fi

# Strip blank lines and # comment lines, then slurp JSONL → array.
BATCH_JSON=$(grep -v '^[[:space:]]*$' "$BATCH_TMP" | grep -v '^[[:space:]]*#' | jq -s '.' 2>&1) || {
  echo "ERROR: could not parse --input as JSONL:" >&2
  # shellcheck disable=SC2001 # sed is clearer than ${var//search/replace}
  # for multi-line indentation of an entire error block
  echo "$BATCH_JSON" | sed 's/^/  /' >&2
  exit 2
}

BATCH_COUNT=$(echo "$BATCH_JSON" | jq 'length')
if [ "$BATCH_COUNT" -eq 0 ]; then
  echo "ERROR: input contained no finding records" >&2
  exit 2
fi

# --- Per-record validation against registry + closed sets ------------------
ERRS=$(jq -nr \
  --argjson batch "$BATCH_JSON" \
  --slurpfile reg "$REGISTRY_FILE" '
def closed_status: ["PASS","FAIL","PARTIAL","N/A","PENDING"];
def closed_method: ["auto","code","interactive","cross-ref","needs-input"];
def closed_maturity: ["Crawl","Walk","Run"];

def source_ok($s):
  if (($s | type) != "string") then false
  elif ($s | startswith("dynamic:") | not) then false
  else
    ($s | sub("^dynamic:"; "")) as $name
    | ($name | length) > 0 and ($name | test("^[A-Za-z0-9._-]+$"))
  end;

($reg[0].checks | map(.check_id)) as $regIds
| ($reg[0].checks | map(select(.requires_user_input == true) | .check_id)) as $manualIds
| [ $batch
    | to_entries[]
    | .key as $i
    | .value as $f
    | (if ($f | type) != "object" then "input[\($i)]: not a JSON object" else empty end),
      (if ($f.check_id // "") == "" then "input[\($i)]: missing check_id" else empty end),
      (if ($f.check_id // "") != "" and (($regIds | index($f.check_id)) | not)
         then "input[\($i)]: check_id \($f.check_id) is not in the registry"
         else empty end),
      (if ($f.status // "") | (. as $x | closed_status | index($x)) | not
         then "input[\($i)] (\($f.check_id // "?")): invalid status \($f.status // "")"
         else empty end),
      (if ($f.method // null) != null
         and (($f.method | (. as $x | closed_method | index($x))) | not)
         then "input[\($i)] (\($f.check_id // "?")): invalid method \($f.method)"
         else empty end),
      (if ($f.maturity // null) != null
         and (($f.maturity | (. as $x | closed_maturity | index($x))) | not)
         then "input[\($i)] (\($f.check_id // "?")): invalid maturity \($f.maturity)"
         else empty end),
      (if ($f.source // null) != null and (source_ok($f.source) | not)
         then "input[\($i)] (\($f.check_id // "?")): invalid source \($f.source) (only dynamic:<filename> with [A-Za-z0-9._-]+ allowed)"
         else empty end),
      (if ($f.status == "PASS") and (($f.finding // "") == "")
         then "input[\($i)] (\($f.check_id // "?")): PASS requires finding" else empty end),
      (if ($f.status == "FAIL" or $f.status == "PARTIAL") and (($f.finding // "") == "")
         then "input[\($i)] (\($f.check_id // "?")): \($f.status) requires finding" else empty end),
      (if ($f.status == "FAIL" or $f.status == "PARTIAL") and (($f.remediation // "") == "")
         then "input[\($i)] (\($f.check_id // "?")): \($f.status) requires remediation" else empty end),
      (if ($f.status == "PENDING") and (($f.question // "") == "")
         then "input[\($i)] (\($f.check_id // "?")): PENDING requires question" else empty end),
      (if ($f.status == "N/A") and (($f.reason // "") == "")
         then "input[\($i)] (\($f.check_id // "?")): N/A requires reason" else empty end),
      # Manual-input guard (mirrors validate-report.sh): a registry check flagged
      # requires_user_input may only be non-PENDING when a human answered
      # (method "interactive") or a WA finding covered it (method "cross-ref").
      (if (($f.check_id // "") != "") and (($manualIds | index($f.check_id)))
          and (($f.status // "") != "PENDING")
          and (([ "interactive", "cross-ref" ] | index($f.method // "needs-input")) | not)
         then "input[\($i)] (\($f.check_id)): check requires user input — a non-PENDING status (\($f.status)) is only allowed with method interactive (user answered) or cross-ref (covered by a WA finding); got method \($f.method // "needs-input"). Mark PENDING if no answer was collected."
         else empty end)
  ] | .[]
')

if [ -n "$ERRS" ]; then
  echo "ERROR: batch validation failed:" >&2
  # shellcheck disable=SC2001 # sed is clearer than ${var//search/replace}
  # for multi-line indentation of an entire error block
  echo "$ERRS" | sed 's/^/  - /' >&2
  exit 2
fi

# Reject duplicates within the batch itself.
DUPS_IN_BATCH=$(echo "$BATCH_JSON" | jq -r '
  [.[] | .check_id]
  | reduce .[] as $id ({}; .[$id] += 1)
  | to_entries
  | map(select(.value > 1))
  | map(.key)[]
')
if [ -n "$DUPS_IN_BATCH" ]; then
  echo "ERROR: batch contains duplicate check_id(s):" >&2
  # shellcheck disable=SC2001 # sed is clearer than ${var//search/replace}
  # for multi-line indentation of an entire error block
  echo "$DUPS_IN_BATCH" | sed 's/^/  - /' >&2
  exit 2
fi

# --- Apply: lock report.json, merge, validate, mv into place ---------------
NEW_TMP=$(mktemp)
BACKUP_TMP=$(mktemp)
LOCK_FILE="${REPORT_JSON}.lock"

# Cleanup tmp files (BATCH_TMP is owned by the existing EXIT trap above; we
# extend it to cover the new tmp files too).
trap 'rm -f "$BATCH_TMP" "$NEW_TMP" "$BACKUP_TMP"' EXIT

apply_merge() {
  jq \
    --argjson batch "$BATCH_JSON" \
    --argjson replace "$REPLACE" '
    . as $rep
    | ($rep.findings // []) as $existing
    | ($existing | map(.check_id)) as $existingIds
    | ($batch | map(.check_id)) as $batchIds
    | (if $replace == 1 then
         # Drop any existing entries whose check_id appears in the batch.
         ($existing | map(select((.check_id as $cid | $batchIds | index($cid)) | not))) + $batch
       else
         (
           ($batchIds | map(select(. as $b | $existingIds | index($b)))) as $conflict
           | if ($conflict | length) > 0 then
               # Mark conflict by emitting a special object the bash side detects.
               { __conflict: $conflict }
             else
               $existing + $batch
             end
         )
       end) as $merged
    | if ($merged | type) == "object" and ($merged | has("__conflict")) then
        $merged
      else
        .findings = $merged
      end
  ' "$REPORT_JSON"
}

# Use flock when available so concurrent helper invocations serialize cleanly.
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  flock -w 10 200 || {
    echo "ERROR: could not acquire lock on ${LOCK_FILE} within 10s" >&2
    exit 1
  }
fi

# Snapshot the current report.json so we can roll back on post-merge
# validation failure.
cp "$REPORT_JSON" "$BACKUP_TMP"

apply_merge > "$NEW_TMP"

# Detect conflict marker.
if jq -e 'has("__conflict")' "$NEW_TMP" >/dev/null 2>&1; then
  echo "ERROR: check_id(s) already exist in report.json (use --replace to overwrite):" >&2
  jq -r '.__conflict[]' "$NEW_TMP" | sed 's/^/  - /' >&2
  exit 3
fi

# --- Step -> child derivation (R4.6, R4.7, R4.8, R4.9) ---------------------
# For each merged finding that carries a non-empty steps[] array, overwrite its
# status with derive_child_status(steps[]) — the deterministic step->child
# rollup. This OVERRIDES any agent-supplied status for step-bearing checks;
# findings without steps[] (or with an empty steps[]) keep their agent-set
# status untouched. This runs BEFORE recompute_parent_rollups (below) so the
# derived child statuses are the operands the parent rollup reads — the three
# tiers steps -> child -> parent all land in the single atomic flocked write.
STEP_BEARING_IDX=$(jq -r '
  (.findings // [])
  | to_entries[]
  | select(((.value.steps // []) | length) > 0)
  | .key' "$NEW_TMP")

for __idx in $STEP_BEARING_IDX; do
  __steps_json=$(jq -c ".findings[${__idx}].steps" "$NEW_TMP")
  __derived=$(derive_child_status "$__steps_json")
  __updated=$(jq --argjson i "$__idx" --arg s "$__derived" \
    '.findings[$i].status = $s' "$NEW_TMP")
  printf '%s\n' "$__updated" > "$NEW_TMP"
done

# --- Recompute parent_rollups from merged findings + lenses (R1.1, R1.11, R1.12)
# This runs AFTER the merge and BEFORE the atomic mv, still inside the flock.
# Recomputes the full array (cheap, identical result, deterministic).
# --partial merges still recompute rollups; only the post-merge validate call
# stays skipped under --partial.
ROLLUPS_JSON=$(recompute_parent_rollups "$NEW_TMP" \
  "${SKILL_ROOT}/references/generative-ai-lens.json" \
  "${SKILL_ROOT}/references/nist-ai-rmf-lens.json" \
  "${SKILL_ROOT}/references/finops-ai-lens.json")

MERGED_WITH_ROLLUPS=$(jq --argjson rollups "$ROLLUPS_JSON" '.parent_rollups = $rollups' "$NEW_TMP")
printf '%s\n' "$MERGED_WITH_ROLLUPS" > "$NEW_TMP"

mv "$NEW_TMP" "$REPORT_JSON"

# Final validation. Coverage may still be incomplete (more pillars to come),
# so coverage failure here is acceptable; we only enforce per-record
# integrity. Per-record errors after merge mean the merged file is invalid —
# roll back to the pre-merge snapshot so the user is not left with a broken
# report.json mid-review.
#
# When --partial is set, skip validation entirely. Callers using --partial
# accept that they must run validate-report.sh once after all batches have
# been merged. This avoids the noisy "FATAL: post-validation rc==3" log line
# that the ERR trap emits even though merge-findings itself returns 0.
if [ "$PARTIAL" -eq 0 ]; then
    POSTVAL_LOG=$(mktemp)
    # Disable the ERR trap for the duration of the validate-report call.
    # validate-report.sh can legitimately exit with rc=3 (coverage incomplete)
    # while merge-findings itself is succeeding; without this guard, the ERR
    # trap fires and prints a confusing "FATAL" line even though we handle
    # rc=3 below.
    trap - ERR
    set +e
    "${SCRIPT_DIR}/validate-report.sh" --data-dir "$DATA_DIR" --quiet 2>"$POSTVAL_LOG"
    rc=$?
    set -e
    trap '__aio2_err_handler $LINENO $? "${BASH_COMMAND}"' ERR
    if [ "$rc" -eq 2 ]; then
      echo "ERROR: post-merge validation failed; rolling back report.json:" >&2
      cat "$POSTVAL_LOG" >&2
      cp "$BACKUP_TMP" "$REPORT_JSON"
      rm -f "$POSTVAL_LOG"
      exit 4
    fi
    # rc==3 (coverage incomplete) is expected mid-review and is not a failure.
    rm -f "$POSTVAL_LOG"
fi

log_info "merge-findings: ${BATCH_COUNT} finding(s) merged into ${REPORT_JSON}"
exit 0
