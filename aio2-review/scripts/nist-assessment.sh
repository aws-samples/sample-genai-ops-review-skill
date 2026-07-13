#!/usr/bin/env bash
# nist-assessment.sh — NIST AI RMF assessment data collection for AIO2 review
#
# Usage:
#   nist-assessment.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--guardrail-ids <id1,id2,...>]
#     [--role-names <name1,name2,...>] [--custom-model-ids <id1,id2,...>]
#
# Writes: $DATA_DIR/nist-summary.json
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
GUARDRAIL_IDS_RAW=""
ROLE_NAMES_RAW=""
CUSTOM_MODEL_IDS_RAW=""
# shellcheck disable=SC2034 # accepted for CLI symmetry with other pillar
# scripts; this assessment doesn't currently need AgentCore runtime data.
AGENTCORE_RUNTIME_IDS_RAW=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> --data-dir <path> [OPTIONS]

Options:
  --region <region>              AWS region (required)
  --profile <profile>            AWS CLI profile name (optional)
  --data-dir <path>              Data directory (required)
  --agent-id <id>                Bedrock Agent ID (optional)
  --guardrail-ids <ids>          Comma-separated guardrail IDs (optional)
  --role-names <names>           Comma-separated IAM role names (optional)
  --custom-model-ids <ids>       Comma-separated custom model IDs (optional)
  --agentcore-runtime-ids <ids>  Comma-separated AgentCore Runtime IDs (optional)
  --help, -h                     Show this help message

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
        --guardrail-ids)
            GUARDRAIL_IDS_RAW="${2:-}"
            shift 2
            ;;
        --guardrail-ids=*)
            GUARDRAIL_IDS_RAW="${1#--guardrail-ids=}"
            shift
            ;;
        --role-names)
            ROLE_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --role-names=*)
            ROLE_NAMES_RAW="${1#--role-names=}"
            shift
            ;;
        --custom-model-ids)
            CUSTOM_MODEL_IDS_RAW="${2:-}"
            shift 2
            ;;
        --custom-model-ids=*)
            CUSTOM_MODEL_IDS_RAW="${1#--custom-model-ids=}"
            shift
            ;;
        --agentcore-runtime-ids)
            AGENTCORE_RUNTIME_IDS_RAW="${2:-}"
            shift 2
            ;;
        --agentcore-runtime-ids=*)
            AGENTCORE_RUNTIME_IDS_RAW="${1#--agentcore-runtime-ids=}"
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

GUARDRAIL_IDS=()
if [ -n "$GUARDRAIL_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && GUARDRAIL_IDS+=("$item")
    done < <(split_csv "$GUARDRAIL_IDS_RAW")
fi

ROLE_NAMES=()
if [ -n "$ROLE_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && ROLE_NAMES+=("$item")
    done < <(split_csv "$ROLE_NAMES_RAW")
fi

CUSTOM_MODEL_IDS=()
if [ -n "$CUSTOM_MODEL_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && CUSTOM_MODEL_IDS+=("$item")
    done < <(split_csv "$CUSTOM_MODEL_IDS_RAW")
fi

# ---------------------------------------------------------------------------
# Phase 1 — parallel fetches
# ---------------------------------------------------------------------------
progress "Phase 1: Fetching NIST assessment data..."

# Agent fetches (if AGENT_ID set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json" \
        aws bedrock-agent list-agent-aliases --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

# Fixed fetches
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-guardrails.json" \
    aws bedrock list-guardrails --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-list-custom-models.json" \
    aws bedrock list-custom-models --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/cloudwatch-describe-alarms.json" \
    aws cloudwatch describe-alarms --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json" \
    aws ec2 describe-vpc-endpoints --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
        --filters "Name=service-name,Values=*bedrock*,*sagemaker*" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json" \
    aws bedrock get-model-invocation-logging-configuration \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Per-guardrail fetches
i=0
while [ "$i" -lt "${#GUARDRAIL_IDS[@]}" ]; do
    gid="${GUARDRAIL_IDS[$i]}"
    gid_safe=$(safe_id "$gid")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-get-guardrail-${gid_safe}.json" \
        aws bedrock get-guardrail --guardrail-identifier "$gid" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-role fetches (IAM is global — no --region flag)
i=0
while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
    role="${ROLE_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/iam-list-attached-role-policies-${role}.json" \
        aws iam list-attached-role-policies --role-name "$role" \
            "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Build nist-summary.json
# ---------------------------------------------------------------------------
progress "Building nist-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- GOVERN: guardrails + invocation logging ---
guardrails_list_file="$RAW_DATA_DIR/bedrock-list-guardrails.json"
has_guardrails="false"
guardrail_count=0

if check_result "$guardrails_list_file"; then
    guardrail_count=$(jq '.guardrails | length' "$guardrails_list_file" 2>/dev/null || echo 0)
    if [ "$guardrail_count" -gt 0 ] 2>/dev/null; then
        has_guardrails="true"
    fi
fi

has_invocation_logging="false"
logging_file="$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json"
if check_result "$logging_file"; then
    cw_enabled=$(jq -r '.loggingConfig.cloudWatchConfig.enabled // false' "$logging_file" 2>/dev/null || echo "false")
    s3_enabled=$(jq -r '.loggingConfig.s3Config.enabled // false' "$logging_file" 2>/dev/null || echo "false")
    if [ "$cw_enabled" = "true" ] || [ "$s3_enabled" = "true" ]; then
        has_invocation_logging="true"
    fi
fi

# --- MAP: custom models + VPC endpoints ---
custom_models_file="$RAW_DATA_DIR/bedrock-list-custom-models.json"
has_custom_models="false"
custom_model_count=0

if check_result "$custom_models_file"; then
    custom_model_count=$(jq '.modelSummaries | length' "$custom_models_file" 2>/dev/null || echo 0)
    if [ "$custom_model_count" -gt 0 ] 2>/dev/null; then
        has_custom_models="true"
    fi
fi

vpc_file="$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json"
has_vpc_endpoints="false"
if check_result "$vpc_file"; then
    ep_count=$(jq '.VpcEndpoints | length' "$vpc_file" 2>/dev/null || echo 0)
    if [ "$ep_count" -gt 0 ] 2>/dev/null; then
        has_vpc_endpoints="true"
    fi
fi

# --- MEASURE: alarms + agent aliases ---
alarms_file="$RAW_DATA_DIR/cloudwatch-describe-alarms.json"
has_alarms="false"
alarm_count=0

if check_result "$alarms_file"; then
    alarm_count=$(jq '.MetricAlarms | length' "$alarms_file" 2>/dev/null || echo 0)
    if [ "$alarm_count" -gt 0 ] 2>/dev/null; then
        has_alarms="true"
    fi
fi

has_agent_aliases="false"
aliases_file="$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json"
if [ -n "$AGENT_ID" ] && check_result "$aliases_file"; then
    alias_count=$(jq '.agentAliasSummaries | length' "$aliases_file" 2>/dev/null || echo 0)
    if [ "$alias_count" -gt 0 ] 2>/dev/null; then
        has_agent_aliases="true"
    fi
fi

# --- MANAGE: IAM policies ---
has_iam_policies="false"
role_count="${#ROLE_NAMES[@]}"

if [ "$role_count" -gt 0 ]; then
    # Check if at least one role has attached policies
    i=0
    while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
        role="${ROLE_NAMES[$i]}"
        attached_file="$RAW_DATA_DIR/iam-list-attached-role-policies-${role}.json"
        if check_result "$attached_file"; then
            policy_count=$(jq '.AttachedPolicies | length' "$attached_file" 2>/dev/null || echo 0)
            if [ "$policy_count" -gt 0 ] 2>/dev/null; then
                has_iam_policies="true"
            fi
        fi
        i=$((i + 1))
    done
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
    --argjson has_guardrails "$has_guardrails" \
    --argjson guardrail_count "$guardrail_count" \
    --argjson has_invocation_logging "$has_invocation_logging" \
    --argjson has_custom_models "$has_custom_models" \
    --argjson custom_model_count "$custom_model_count" \
    --argjson has_vpc_endpoints "$has_vpc_endpoints" \
    --argjson has_alarms "$has_alarms" \
    --argjson alarm_count "$alarm_count" \
    --argjson has_agent_aliases "$has_agent_aliases" \
    --argjson has_iam_policies "$has_iam_policies" \
    --argjson role_count "$role_count" \
    '{
        framework: "nist",
        timestamp: $timestamp,
        errors: $errors,
        govern: {
            has_guardrails: $has_guardrails,
            guardrail_count: $guardrail_count,
            has_invocation_logging: $has_invocation_logging
        },
        map: {
            has_custom_models: $has_custom_models,
            custom_model_count: $custom_model_count,
            has_vpc_endpoints: $has_vpc_endpoints
        },
        measure: {
            has_alarms: $has_alarms,
            alarm_count: $alarm_count,
            has_agent_aliases: $has_agent_aliases
        },
        manage: {
            has_iam_policies: $has_iam_policies,
            role_count: $role_count
        }
    }' > "$DATA_DIR/nist-summary.json"

progress "nist-summary.json written to ${DATA_DIR}/nist-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
