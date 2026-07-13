#!/usr/bin/env bash
# check-ownership.sh — verify that a sub-skill's findings JSONL covers
# exactly the set of check_ids owned by that sub-skill (per references/
# owned-checks.json). Used as a guard before merge-findings.sh so a pillar
# can't silently drop or double-claim a check.
#
# Usage:
#   check-ownership.sh --owner <owner-key> --input <findings.jsonl>
#   check-ownership.sh --owner WA:Security --input security-findings.jsonl
#
# Multiple --owner values are allowed when a sub-skill spans multiple
# canonical owners (NIST and FinOps each have several function/domain owners
# served by one sub-skill).
#
# Exit codes:
#   0  the JSONL covers exactly the union of owned IDs (no missing, no extra)
#   1  argument or path error
#   2  coverage mismatch (missing / extra / duplicate IDs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  check-ownership.sh --owner <owner-key> [--owner <owner-key>...] --input <jsonl>

Required:
  --owner <key>   Canonical owner key from references/owned-checks.json
                  (e.g., WA:Security, NIST:Govern, FinOps:Optimize). Repeat
                  for sub-skills that span multiple owners (e.g., NIST has
                  four function owners served by nist-ai-rmf-assessment.md).
  --input <file>  JSONL with one finding per non-empty, non-comment line.

Exit codes:
  0  the JSONL covers exactly the union of owned IDs (no missing, no extra)
  1  argument or path error
  2  coverage mismatch (missing / extra / duplicate IDs)
USAGE_EOF
}

OWNERS=()
INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)   OWNERS+=("${2:-}"); shift 2 ;;
    --owner=*) OWNERS+=("${1#--owner=}"); shift ;;
    --input)   INPUT="${2:-}"; shift 2 ;;
    --input=*) INPUT="${1#--input=}"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
  esac
done

if [ "${#OWNERS[@]}" -eq 0 ] || [ -z "$INPUT" ]; then
  echo "ERROR: --owner (one or more) and --input are required" >&2
  usage >&2
  exit 1
fi
if [ ! -f "$INPUT" ]; then
  echo "ERROR: --input file not found: ${INPUT}" >&2
  exit 1
fi

SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OWNED_FILE="${SKILL_ROOT}/references/owned-checks.json"
[ ! -f "$OWNED_FILE" ] && { echo "ERROR: owned-checks.json not found: ${OWNED_FILE}" >&2; exit 1; }

# Build expected set: union of owned IDs across all requested owners.
OWNERS_JSON=$(printf '%s\n' "${OWNERS[@]}" | jq -R . | jq -s .)

EXPECTED=$(jq -c \
  --argjson owners "$OWNERS_JSON" \
  '
    [ $owners[] as $k
      | (.owners[$k].ids // (
          ["__missing_owner_key:" + $k]
        ))
    ] | flatten | unique
  ' "$OWNED_FILE")

# Detect bogus owner keys via a sentinel; fail clearly.
if echo "$EXPECTED" | jq -e '.[] | startswith("__missing_owner_key:")' >/dev/null 2>&1; then
  echo "ERROR: unknown --owner value(s):" >&2
  echo "$EXPECTED" | jq -r '.[] | select(startswith("__missing_owner_key:")) | sub("^__missing_owner_key:"; "")' \
    | sed 's/^/  - /' >&2
  echo "  (allowed keys are the top-level entries of references/owned-checks.json under .owners)" >&2
  exit 1
fi

# Build observed set from the JSONL.
OBSERVED=$(grep -v '^[[:space:]]*$' "$INPUT" \
  | grep -v '^[[:space:]]*#' \
  | jq -s '[.[] | .check_id // ""]')

REPORT=$(jq -n \
  --argjson expected "$EXPECTED" \
  --argjson observed "$OBSERVED" '
  ($observed | unique) as $obs
  | ($observed | length) as $obs_total
  | (($observed | length) - ($obs | length)) as $duplicates
  | ($observed | reduce .[] as $id ({}; .[$id] += 1)
       | to_entries | map(select(.value > 1)) | map(.key)) as $dup_ids
  | {
      expected_count: ($expected | length),
      observed_count: $obs_total,
      missing: ($expected - $obs),
      extra: ($obs - $expected),
      duplicate_ids: $dup_ids
    }
')

MISSING_COUNT=$(echo "$REPORT" | jq -r '.missing | length')
EXTRA_COUNT=$(echo "$REPORT" | jq -r '.extra | length')
DUP_COUNT=$(echo "$REPORT" | jq -r '.duplicate_ids | length')
EXP=$(echo "$REPORT" | jq -r '.expected_count')
OBS=$(echo "$REPORT" | jq -r '.observed_count')

if [ "$MISSING_COUNT" -gt 0 ] || [ "$EXTRA_COUNT" -gt 0 ] || [ "$DUP_COUNT" -gt 0 ]; then
  echo "ERROR: ownership check failed for owners=$(IFS=,; echo "${OWNERS[*]}")" >&2
  echo "  expected ${EXP} ID(s); JSONL provided ${OBS}" >&2
  if [ "$DUP_COUNT" -gt 0 ]; then
    echo "  duplicate check_id(s) in JSONL:" >&2
    echo "$REPORT" | jq -r '.duplicate_ids[]' | sed 's/^/    - /' >&2
  fi
  if [ "$MISSING_COUNT" -gt 0 ]; then
    echo "  missing check_id(s) (expected by owner, not in JSONL):" >&2
    echo "$REPORT" | jq -r '.missing[]' | sed 's/^/    - /' >&2
  fi
  if [ "$EXTRA_COUNT" -gt 0 ]; then
    echo "  unexpected check_id(s) (in JSONL, not owned by these owners):" >&2
    echo "$REPORT" | jq -r '.extra[]' | sed 's/^/    - /' >&2
  fi
  exit 2
fi

log_info "check-ownership: OK (${OBS}/${EXP} IDs covered, owners=$(IFS=,; echo "${OWNERS[*]}"))"
exit 0
