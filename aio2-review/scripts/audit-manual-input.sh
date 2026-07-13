#!/usr/bin/env bash
# audit-manual-input.sh — Keep the registry's requires_user_input flags in sync
# with the framework YAML source of truth, and print the manual-input mapping.
#
# A check REQUIRES manual user input when it cannot be resolved from AWS CLI
# data or workspace code — i.e. its `assessment_methods` in the framework YAML
# is exactly ["interactive"]. Those checks MUST stay PENDING unless a human
# answers them. `references/check-registry.json` records this with
# `requires_user_input: true`, and validate-report.sh / merge-findings.sh
# enforce it (a flagged check may only be non-PENDING with method
# "interactive" or "cross-ref").
#
# This audit re-derives the interactive-only set from the YAMLs and compares it
# to the registry flags so the two never drift. WA core best practices have no
# YAML `assessment_methods` and are never interactive-only, so the derived set
# comes entirely from the NIST and FinOps YAMLs.
#
# Usage:
#   audit-manual-input.sh [--list]
#
#   --list   Print the mapping (check_id -> framework) and exit 0 without
#            enforcing sync. Without --list, the script fails (exit 1) if the
#            registry flags do not match the YAML-derived set.
#
# Exit codes:
#   0  registry flags match the YAML-derived set (or --list)
#   1  drift detected, or a required file is missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF="${SKILL_ROOT}/references"
REGISTRY_FILE="${REF}/check-registry.json"
NIST_YAML="${REF}/nist-ai-rmf-checks.yaml"
FINOPS_YAML="${REF}/finops-ai-checks.yaml"

LIST_ONLY=0
case "${1:-}" in
  --list) LIST_ONLY=1 ;;
  "") ;;
  --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "ERROR: unknown argument: '${1}'" >&2; exit 1 ;;
esac

for f in "$REGISTRY_FILE" "$NIST_YAML" "$FINOPS_YAML"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: ${f}" >&2
    exit 1
  fi
done

# Derive interactive-only check IDs from a YAML file: emit each id whose
# assessment_methods is exactly ["interactive"]. Bracket class [][" ] is the
# set { ] [ " space } (a literal ] must lead a bracket expression).
derive_interactive_only() {
  awk '
    /^[[:space:]]*-[[:space:]]+id:/ {
      id=$0; sub(/^[^:]*:[[:space:]]*/, "", id); gsub(/[][" ]/, "", id)
    }
    /^[[:space:]]+assessment_methods:/ {
      m=$0; sub(/^[^:]*:[[:space:]]*/, "", m); gsub(/[][" ]/, "", m)
      if (m == "interactive" && id != "") print id
    }
  ' "$1"
}

DERIVED=$(
  { derive_interactive_only "$NIST_YAML"; derive_interactive_only "$FINOPS_YAML"; } \
    | grep -v '^$' | sort -u
)

FLAGGED=$(jq -r '.checks[] | select(.requires_user_input == true) | .check_id' "$REGISTRY_FILE" | sort -u)

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "Checks that REQUIRE manual user input (assessment_methods == [\"interactive\"]):"
  jq -r '
    .checks[]
    | select(.requires_user_input == true)
    | "  \(.check_id)\t[\(.frameworks | join(","))]\t\(.category)"
  ' "$REGISTRY_FILE" | sort
  echo ""
  echo "Total: $(printf '%s\n' "$FLAGGED" | grep -c . || true)"
  exit 0
fi

MISSING=$(comm -23 <(printf '%s\n' "$DERIVED") <(printf '%s\n' "$FLAGGED"))
EXTRA=$(comm -13 <(printf '%s\n' "$DERIVED") <(printf '%s\n' "$FLAGGED"))

rc=0
if [ -n "$MISSING" ]; then
  echo "ERROR: interactive-only in YAML but NOT flagged requires_user_input in registry:" >&2
  printf '%s\n' "$MISSING" | sed 's/^/  - /' >&2
  rc=1
fi
if [ -n "$EXTRA" ]; then
  echo "ERROR: flagged requires_user_input in registry but NOT interactive-only in YAML:" >&2
  printf '%s\n' "$EXTRA" | sed 's/^/  - /' >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "audit-manual-input: OK ($(printf '%s\n' "$FLAGGED" | grep -c . || true) checks in sync)"
fi
exit "$rc"
