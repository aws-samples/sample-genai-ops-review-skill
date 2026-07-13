#!/usr/bin/env bash
# dynamic-cli.sh — Dynamic CLI fallback for supplementary service queries.
#
# Allows the orchestrator to issue sanctioned, read-only AWS CLI commands for
# services outside the pre-scripted pipeline, subject to an allowlist of verbs
# and a documented file-naming convention under ${DATA_DIR}/data/.
#
# Usage:
#   dynamic-cli.sh --data-dir <dir> --check-id <id> --service <svc> \
#     --operation <op> [--resource-id <id>] [--region <region>] \
#     [--profile <profile>] [--arg k=v]... [--dry-run]
#
# On success, emits one TSV line on stdout: <check_id>\t<output_path>
#
# Exit codes:
#   0 — success (or dry-run passed)
#   1 — argument / validation error (bad verb, unknown check_id, missing args)
#   5 — state validation failure: path/library issues (dry-run pre-checks)
#   6 — state validation failure: registry issues (dry-run pre-checks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

# ---------------------------------------------------------------------------
# Read-only operation allowlist prefixes
# ---------------------------------------------------------------------------
READONLY_PREFIXES="get- list- describe- head- lookup- select-"

# ---------------------------------------------------------------------------
# Script-specific arguments
# ---------------------------------------------------------------------------
CHECK_ID=""
SERVICE=""
OPERATION=""
RESOURCE_ID=""
DRY_RUN=0
EXTRA_ARGS=()

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --data-dir <dir> --check-id <id> --service <svc> \\
         --operation <op> [--resource-id <id>] [--region <region>] \\
         [--profile <profile>] [--arg k=v]... [--dry-run]

Options:
  --data-dir <dir>       Data directory (required)
  --check-id <id>        Check ID from check-registry.json (required)
  --service <svc>        AWS CLI service name (required)
  --operation <op>       AWS CLI operation (must be read-only) (required)
  --resource-id <id>     Optional resource identifier (used in output filename)
  --region <region>      AWS region (required)
  --profile <profile>    AWS CLI profile (optional)
  --arg <k=v>            Additional CLI argument (repeatable)
  --dry-run              Validate and print planned command without executing

Exit codes:
  0  Success or dry-run passed
  1  Argument/validation error
  5  State validation failure (dry-run pre-checks)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_common_args "$@"

# Process remaining args for script-specific flags.
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [ $# -gt 0 ]; do
    case "$1" in
        --check-id)
            CHECK_ID="${2:-}"
            shift 2
            ;;
        --check-id=*)
            CHECK_ID="${1#--check-id=}"
            shift
            ;;
        --service)
            SERVICE="${2:-}"
            shift 2
            ;;
        --service=*)
            SERVICE="${1#--service=}"
            shift
            ;;
        --operation)
            OPERATION="${2:-}"
            shift 2
            ;;
        --operation=*)
            OPERATION="${1#--operation=}"
            shift
            ;;
        --resource-id)
            RESOURCE_ID="${2:-}"
            shift 2
            ;;
        --resource-id=*)
            RESOURCE_ID="${1#--resource-id=}"
            shift
            ;;
        --arg)
            EXTRA_ARGS+=("${2:-}")
            shift 2
            ;;
        --arg=*)
            EXTRA_ARGS+=("${1#--arg=}")
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# State validation (runs for both normal and dry-run mode)
# ---------------------------------------------------------------------------

# Validate script can resolve its own directory via BASH_SOURCE[0]
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "state validation failed: cannot resolve script directory from BASH_SOURCE[0]" >&2
    exit 5
fi

# Validate sibling _common.sh is loadable (already sourced above, but confirm)
if [ ! -f "${SCRIPT_DIR}/_common.sh" ]; then
    echo "state validation failed: _common.sh not found at ${SCRIPT_DIR}/_common.sh" >&2
    exit 5
fi

# Validate required arguments
if [ -z "$CHECK_ID" ]; then
    echo "ERROR: --check-id is required" >&2
    exit 1
fi
if [ -z "$SERVICE" ]; then
    echo "ERROR: --service is required" >&2
    exit 1
fi
if [ -z "$OPERATION" ]; then
    echo "ERROR: --operation is required" >&2
    exit 1
fi
if [ -z "$DATA_DIR" ]; then
    echo "ERROR: --data-dir is required" >&2
    exit 1
fi
if [ -z "$REGION" ]; then
    echo "ERROR: --region is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Load registry and validate check-id
# ---------------------------------------------------------------------------

# Validate Check_Registry is loadable
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_FILE="${SKILL_ROOT}/references/check-registry.json"

if [ ! -f "$REGISTRY_FILE" ]; then
    echo "state validation failed: check-registry.json not found at ${REGISTRY_FILE}" >&2
    exit 6
fi

# Load registry and verify it returns valid JSON
REGISTRY_JSON=$(load_registry)
if [ -z "$REGISTRY_JSON" ] || ! printf '%s\n' "$REGISTRY_JSON" | jq empty 2>/dev/null; then
    echo "state validation failed: check-registry.json is not valid JSON" >&2
    exit 6
fi

# Verify check_id is in the registry
CHECK_EXISTS=$(printf '%s\n' "$REGISTRY_JSON" | jq --arg cid "$CHECK_ID" '
    if type == "array" then
        map(select(.check_id == $cid)) | length
    else
        .checks // [] | map(select(.check_id == $cid)) | length
    end
' 2>/dev/null || echo "0")

if [ "$CHECK_EXISTS" = "0" ]; then
    echo "unknown check_id: ${CHECK_ID}; not in check-registry.json" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate operation against read-only allowlist
# ---------------------------------------------------------------------------
is_readonly=0
for prefix in $READONLY_PREFIXES; do
    case "$OPERATION" in
        ${prefix}*)
            is_readonly=1
            break
            ;;
    esac
done

if [ "$is_readonly" -eq 0 ]; then
    echo "non-read-only verb rejected: ${OPERATION}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Compute output filename
# ---------------------------------------------------------------------------

# Sanitize resource-id to kebab-case (same pattern as discover-resources.sh)
RESOURCE_SLUG=""
if [ -n "$RESOURCE_ID" ]; then
    RESOURCE_SLUG=$(echo "$RESOURCE_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
fi

# Build output path: ${DATA_DIR}/data/<service>-<operation>[-<resource-id>].json
if [ -n "$RESOURCE_SLUG" ]; then
    OUTPUT_FILE="${DATA_DIR}/data/${SERVICE}-${OPERATION}-${RESOURCE_SLUG}.json"
else
    OUTPUT_FILE="${DATA_DIR}/data/${SERVICE}-${OPERATION}.json"
fi

# ---------------------------------------------------------------------------
# Build the AWS CLI command
# ---------------------------------------------------------------------------
AWS_CMD=(aws "$SERVICE" "$OPERATION")

# Add extra args (k=v pairs become --k v)
for kv in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
    local_key="${kv%%=*}"
    local_val="${kv#*=}"
    AWS_CMD+=(--"$local_key" "$local_val")
done

# Add region and profile
AWS_CMD+=(--region "$REGION")
if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD+=(--profile "$AWS_PROFILE")
fi
AWS_CMD+=(--output json)

# ---------------------------------------------------------------------------
# Dry-run mode: print planned command and output path, exit 0
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: command: ${AWS_CMD[*]}"
    echo "dry-run: output: ${OUTPUT_FILE}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Execute via fetch_or_cache
# ---------------------------------------------------------------------------

# Ensure data directory exists
validate_data_dir

fetch_or_cache "$OUTPUT_FILE" "${AWS_CMD[@]}"

# Emit TSV line for orchestrator binding
printf '%s\t%s\n' "$CHECK_ID" "$OUTPUT_FILE"
