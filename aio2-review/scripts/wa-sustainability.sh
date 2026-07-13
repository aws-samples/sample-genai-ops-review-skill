#!/usr/bin/env bash
# wa-sustainability.sh — WA Sustainability pillar data collection for AIO2 review
#
# Usage:
#   wa-sustainability.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--endpoint-names <name1,name2,...>]
#     [--lambda-names <name1,name2,...>]
#
# Writes: $DATA_DIR/sustainability-summary.json
#
# Exit codes:
#   0 — success (errors may have been collected but are non-fatal)
#   2 — one or more errors were collected during execution

set -euo pipefail

# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

# ---------------------------------------------------------------------------
# Script-specific globals
# ---------------------------------------------------------------------------
AGENT_ID=""
ENDPOINT_NAMES_RAW=""
LAMBDA_NAMES_RAW=""
# shellcheck disable=SC2034 # accepted for CLI symmetry with other pillar
# scripts; this pillar's checks don't currently need KB-level data.
KB_IDS_RAW=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> --data-dir <path> [OPTIONS]

Options:
  --region <region>          AWS region (required)
  --profile <profile>        AWS CLI profile name (optional)
  --data-dir <path>          Data directory (required)
  --agent-id <id>            Bedrock Agent ID (optional)
  --endpoint-names <names>   Comma-separated SageMaker endpoint names (optional)
  --lambda-names <names>     Comma-separated Lambda function names (optional)
  --kb-ids <ids>             Comma-separated Knowledge Base IDs (optional)
  --help, -h                 Show this help message

Exit codes:
  0  Success
  2  Partial success (some commands failed)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_common_args "$@"

set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [ $# -gt 0 ]; do
    case "$1" in
        --agent-id)
            AGENT_ID="${2:-}"
            shift 2
            ;;
        --agent-id=*)
            AGENT_ID="${1#--agent-id=}"
            shift
            ;;
        --endpoint-names)
            ENDPOINT_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --endpoint-names=*)
            ENDPOINT_NAMES_RAW="${1#--endpoint-names=}"
            shift
            ;;
        --lambda-names)
            LAMBDA_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --lambda-names=*)
            LAMBDA_NAMES_RAW="${1#--lambda-names=}"
            shift
            ;;
        --kb-ids)
            KB_IDS_RAW="${2:-}"
            shift 2
            ;;
        --kb-ids=*)
            KB_IDS_RAW="${1#--kb-ids=}"
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
# Validation
# ---------------------------------------------------------------------------
validate_deps
validate_common_args
validate_aws_credentials
validate_data_dir
manifest_load_resource_ids "$DATA_DIR"

# ---------------------------------------------------------------------------
# Split comma-separated inputs into arrays (bash 3.2 compatible)
# ---------------------------------------------------------------------------
split_csv() {
    echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

ENDPOINT_NAMES=()
if [ -n "$ENDPOINT_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && ENDPOINT_NAMES+=("$item")
    done < <(split_csv "$ENDPOINT_NAMES_RAW")
fi

LAMBDA_NAMES=()
if [ -n "$LAMBDA_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && LAMBDA_NAMES+=("$item")
    done < <(split_csv "$LAMBDA_NAMES_RAW")
fi

# ---------------------------------------------------------------------------
# Phase 1 — parallel fetches
# ---------------------------------------------------------------------------
progress "Phase 1: Fetching sustainability data..."

# Agent fetch (if AGENT_ID set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

# Per-endpoint fetches
i=0
while [ "$i" -lt "${#ENDPOINT_NAMES[@]}" ]; do
    ep_name="${ENDPOINT_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/sagemaker-describe-endpoint-${ep_name}.json" \
        aws sagemaker describe-endpoint --endpoint-name "$ep_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-lambda fetches
i=0
while [ "$i" -lt "${#LAMBDA_NAMES[@]}" ]; do
    fn_name="${LAMBDA_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/lambda-get-function-configuration-${fn_name}.json" \
        aws lambda get-function-configuration --function-name "$fn_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# S3 bucket listing for lifecycle checks (GENSUS02_BP01)
fetch_or_cache "$RAW_DATA_DIR/s3api-list-buckets.json" \
    aws s3api list-buckets \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Phase 2 — S3 lifecycle configs (depend on Phase 1 list-buckets)
# ---------------------------------------------------------------------------
progress "Phase 2: Fetching S3 lifecycle configs..."

s3_buckets_file="$RAW_DATA_DIR/s3api-list-buckets.json"
if check_result "$s3_buckets_file"; then
    bucket_names=$(jq -r '[.Buckets[]?.Name] | .[0:5] | .[]' "$s3_buckets_file" 2>/dev/null || true)
    if [ -n "$bucket_names" ]; then
        while IFS= read -r bname; do
            [ -z "$bname" ] && continue
            bname_safe=$(echo "$bname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
            fetch_or_cache "$RAW_DATA_DIR/s3api-get-bucket-lifecycle-${bname_safe}.json" \
                aws s3api get-bucket-lifecycle-configuration --bucket "$bname" \
                    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        done <<< "$bucket_names"
        wait
    fi
fi

progress "Phase 2 complete."

# ---------------------------------------------------------------------------
# Build sustainability-summary.json
# ---------------------------------------------------------------------------
progress "Building sustainability-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Agent ---
agent_model_id="null"
agent_idle_ttl=0

agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
if [ -n "$AGENT_ID" ] && check_result "$agent_file"; then
    agent_model_id=$(jq -r '.agent.foundationModel // "unknown"' "$agent_file" 2>/dev/null || echo "unknown")
    agent_idle_ttl=$(jq -r '.agent.idleSessionTTLInSeconds // 0' "$agent_file" 2>/dev/null || echo 0)
fi

# --- SageMaker endpoints ---
ep_parts=""
i=0
while [ "$i" -lt "${#ENDPOINT_NAMES[@]}" ]; do
    ep_name="${ENDPOINT_NAMES[$i]}"
    ep_file="$RAW_DATA_DIR/sagemaker-describe-endpoint-${ep_name}.json"
    instance_type="unknown"

    if check_result "$ep_file"; then
        instance_type=$(jq -r '.ProductionVariants[0].CurrentInstanceType // "unknown"' "$ep_file" 2>/dev/null || echo "unknown")
    fi

    entry=$(jq -cn \
        --arg name "$ep_name" \
        --arg instance_type "$instance_type" \
        '{name: $name, instance_type: $instance_type}')

    if [ -n "$ep_parts" ]; then
        ep_parts="${ep_parts},${entry}"
    else
        ep_parts="${entry}"
    fi
    i=$((i + 1))
done
endpoints_json="[${ep_parts}]"

# --- Lambda functions ---
lambda_parts=""
i=0
while [ "$i" -lt "${#LAMBDA_NAMES[@]}" ]; do
    fn_name="${LAMBDA_NAMES[$i]}"
    fn_file="$RAW_DATA_DIR/lambda-get-function-configuration-${fn_name}.json"
    memory=0
    architecture="x86_64"

    if check_result "$fn_file"; then
        memory=$(jq -r '.MemorySize // 0' "$fn_file" 2>/dev/null || echo 0)
        architecture=$(jq -r '.Architectures[0] // "x86_64"' "$fn_file" 2>/dev/null || echo "x86_64")
    fi

    entry=$(jq -cn \
        --arg name "$fn_name" \
        --argjson memory "$memory" \
        --arg architecture "$architecture" \
        '{name: $name, memory: $memory, architecture: $architecture}')

    if [ -n "$lambda_parts" ]; then
        lambda_parts="${lambda_parts},${entry}"
    else
        lambda_parts="${entry}"
    fi
    i=$((i + 1))
done
lambda_json="[${lambda_parts}]"

# --- S3 lifecycle (GENSUS02_BP01) ---
s3_lifecycle_collected="false"
s3_lifecycle_buckets="[]"
s3_buckets_file="$RAW_DATA_DIR/s3api-list-buckets.json"
if check_result "$s3_buckets_file"; then
    s3_lifecycle_collected="true"
    s3_parts=""
    bucket_names=$(jq -r '[.Buckets[]?.Name] | .[0:5] | .[]' "$s3_buckets_file" 2>/dev/null || true)
    if [ -n "$bucket_names" ]; then
        while IFS= read -r bname; do
            [ -z "$bname" ] && continue
            bname_safe=$(echo "$bname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
            lc_file="$RAW_DATA_DIR/s3api-get-bucket-lifecycle-${bname_safe}.json"
            has_lifecycle="false"
            has_tiering="false"
            if check_result "$lc_file"; then
                has_lifecycle="true"
                if jq -e '.Rules[]? | select(.Transitions[]?.StorageClass == "INTELLIGENT_TIERING")' "$lc_file" >/dev/null 2>&1; then
                    has_tiering="true"
                fi
            fi
            entry=$(jq -cn --arg name "$bname" --argjson has_lifecycle_rules "$has_lifecycle" --argjson has_intelligent_tiering "$has_tiering" \
                '{name: $name, has_lifecycle_rules: $has_lifecycle_rules, has_intelligent_tiering: $has_intelligent_tiering}')
            if [ -n "$s3_parts" ]; then
                s3_parts="${s3_parts},${entry}"
            else
                s3_parts="${entry}"
            fi
        done <<< "$bucket_names"
    fi
    [ -n "$s3_parts" ] && s3_lifecycle_buckets="[${s3_parts}]"
fi

# --- Collect errors JSON ---
errors_json="[]"
if [ "${#COLLECTED_ERRORS[@]}" -gt 0 ]; then
    errors_json=$(printf '%s\n' "${COLLECTED_ERRORS[@]}" | jq -R . | jq -s .)
fi

# --- Write summary ---
jq -n \
    --arg timestamp "$TIMESTAMP" \
    --argjson errors "$errors_json" \
    --arg agent_model_id "$agent_model_id" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson sagemaker_endpoints "$endpoints_json" \
    --argjson lambda_functions "$lambda_json" \
    --argjson s3_lifecycle_collected "$s3_lifecycle_collected" \
    --argjson s3_lifecycle_buckets "$s3_lifecycle_buckets" \
    '{
        pillar: "sustainability",
        timestamp: $timestamp,
        errors: $errors,
        agent: {model_id: $agent_model_id, idle_session_ttl: $agent_idle_ttl},
        sagemaker_endpoints: $sagemaker_endpoints,
        lambda_functions: $lambda_functions,
        s3_lifecycle: { collected: $s3_lifecycle_collected, buckets: $s3_lifecycle_buckets }
    }' > "$DATA_DIR/sustainability-summary.json"

progress "sustainability-summary.json written to ${DATA_DIR}/sustainability-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
