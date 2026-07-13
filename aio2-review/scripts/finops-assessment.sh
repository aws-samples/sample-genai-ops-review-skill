#!/usr/bin/env bash
# finops-assessment.sh — FinOps AI assessment data collection for AIO2 review
#
# Usage:
#   finops-assessment.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--guardrail-ids <id1,id2,...>]
#     [--endpoint-names <name1,name2,...>] [--account-id <id>]
#
# Writes: $DATA_DIR/finops-summary.json
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
ENDPOINT_NAMES_RAW=""
# shellcheck disable=SC2034 # accepted for CLI symmetry with other pillar
# scripts; this assessment doesn't currently need endpoint-config-level data.
ENDPOINT_CONFIG_NAMES_RAW=""
# shellcheck disable=SC2034 # accepted for CLI symmetry with other pillar
# scripts; this assessment doesn't currently need KB-level data.
KB_IDS_RAW=""
ACCOUNT_ID_ARG=""

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
  --guardrail-ids <ids>      Comma-separated guardrail IDs (optional)
  --endpoint-names <names>   Comma-separated SageMaker endpoint names (optional)
  --endpoint-config-names <names>  Comma-separated SageMaker endpoint config names (optional)
  --kb-ids <ids>             Comma-separated Knowledge Base IDs (optional)
  --account-id <id>          AWS account ID for Budgets API (optional)
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
        --guardrail-ids)
            GUARDRAIL_IDS_RAW="${2:-}"
            shift 2
            ;;
        --guardrail-ids=*)
            GUARDRAIL_IDS_RAW="${1#--guardrail-ids=}"
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
        --account-id)
            ACCOUNT_ID_ARG="${2:-}"
            shift 2
            ;;
        --account-id=*)
            ACCOUNT_ID_ARG="${1#--account-id=}"
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
        --endpoint-config-names)
            ENDPOINT_CONFIG_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --endpoint-config-names=*)
            ENDPOINT_CONFIG_NAMES_RAW="${1#--endpoint-config-names=}"
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

ENDPOINT_NAMES=()
if [ -n "$ENDPOINT_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && ENDPOINT_NAMES+=("$item")
    done < <(split_csv "$ENDPOINT_NAMES_RAW")
fi

# ---------------------------------------------------------------------------
# Phase 1 — parallel fetches
# ---------------------------------------------------------------------------
progress "Phase 1: Fetching FinOps data..."

# Agent fetch (if AGENT_ID set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

# Fixed fetches
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json" \
    aws bedrock list-provisioned-model-throughputs \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-list-guardrails.json" \
    aws bedrock list-guardrails --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

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

# Per-endpoint fetches
i=0
while [ "$i" -lt "${#ENDPOINT_NAMES[@]}" ]; do
    ep_name="${ENDPOINT_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/sagemaker-describe-endpoint-${ep_name}.json" \
        aws sagemaker describe-endpoint --endpoint-name "$ep_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Cost Explorer — always us-east-1; may fail without special permissions
# Use set +e / set -e so a failure writes "null" via fetch_or_cache
set +e
fetch_or_cache "$RAW_DATA_DIR/ce-get-cost-and-usage.json" \
    aws ce get-cost-and-usage \
        --time-period "Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d)" \
        --granularity MONTHLY \
        --metrics BlendedCost \
        --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock","Amazon SageMaker"]}}' \
        --region us-east-1 "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
set -e

# Budgets — always us-east-1; only if ACCOUNT_ID_ARG set; may fail without permissions
if [ -n "$ACCOUNT_ID_ARG" ]; then
    set +e
    fetch_or_cache "$RAW_DATA_DIR/budgets-describe-budgets.json" \
        aws budgets describe-budgets --account-id "$ACCOUNT_ID_ARG" \
            --region us-east-1 "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    set -e
fi

# Cost anomaly detection (FIN-MGT-03)
set +e
fetch_or_cache "$RAW_DATA_DIR/ce-get-anomaly-monitors.json" \
    aws ce get-anomaly-monitors \
        --region us-east-1 "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/ce-get-anomaly-subscriptions.json" \
    aws ce get-anomaly-subscriptions \
        --region us-east-1 "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Cost allocation tags (FIN-UND-01, FIN-UND-03)
fetch_or_cache "$RAW_DATA_DIR/ce-list-cost-allocation-tags.json" \
    aws ce list-cost-allocation-tags --status Active \
        --region us-east-1 "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
set -e

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Build finops-summary.json
# ---------------------------------------------------------------------------
progress "Building finops-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- UNDERSTAND: invocation logging, cost data, budgets ---
has_invocation_logging="false"
logging_file="$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json"
if check_result "$logging_file"; then
    cw_enabled=$(jq -r '.loggingConfig.cloudWatchConfig.enabled // false' "$logging_file" 2>/dev/null || echo "false")
    s3_enabled=$(jq -r '.loggingConfig.s3Config.enabled // false' "$logging_file" 2>/dev/null || echo "false")
    if [ "$cw_enabled" = "true" ] || [ "$s3_enabled" = "true" ]; then
        has_invocation_logging="true"
    fi
fi

has_cost_data="false"
ce_file="$RAW_DATA_DIR/ce-get-cost-and-usage.json"
if check_result "$ce_file"; then
    has_cost_data="true"
fi

has_budgets="false"
budgets_total_count=0
budgets_has_ai_budgets="false"
budgets_alert_count=0
budgets_file="$RAW_DATA_DIR/budgets-describe-budgets.json"
if [ -n "$ACCOUNT_ID_ARG" ] && check_result "$budgets_file"; then
    budgets_total_count=$(jq '[.Budgets[]?] | length' "$budgets_file" 2>/dev/null || echo 0)
    if [ "$budgets_total_count" -gt 0 ] 2>/dev/null; then
        has_budgets="true"
    fi
    if jq -e '.Budgets[]? | select(.BudgetName | test("ai|agent|bedrock|genai|ml|sagemaker"; "i"))' "$budgets_file" >/dev/null 2>&1; then
        budgets_has_ai_budgets="true"
    fi
    budgets_alert_count=$(jq '[.Budgets[]?.Notifications[]?] | length' "$budgets_file" 2>/dev/null || echo 0)
fi

# --- OPTIMIZE: guardrail prefiltering, provisioned throughput ---
has_guardrail_prefiltering="false"
i=0
while [ "$i" -lt "${#GUARDRAIL_IDS[@]}" ]; do
    gid="${GUARDRAIL_IDS[$i]}"
    gid_safe=$(safe_id "$gid")
    gfile="$RAW_DATA_DIR/bedrock-get-guardrail-${gid_safe}.json"
    if check_result "$gfile"; then
        filter_count=$(jq '(.contentPolicy.filters | length) // 0' "$gfile" 2>/dev/null || echo 0)
        if [ "$filter_count" -gt 0 ] 2>/dev/null; then
            has_guardrail_prefiltering="true"
        fi
    fi
    i=$((i + 1))
done

pmt_file="$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json"
has_provisioned_throughput="false"
provisioned_throughput_count=0
if check_result "$pmt_file"; then
    provisioned_throughput_count=$(jq '.provisionedModelSummaries | length' "$pmt_file" 2>/dev/null || echo 0)
    if [ "$provisioned_throughput_count" -gt 0 ] 2>/dev/null; then
        has_provisioned_throughput="true"
    fi
fi

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

# --- Cost anomaly (FIN-MGT-03) ---
anomaly_monitors_file="$RAW_DATA_DIR/ce-get-anomaly-monitors.json"
anomaly_subs_file="$RAW_DATA_DIR/ce-get-anomaly-subscriptions.json"
cost_anomaly_collected="false"
cost_anomaly_monitor_count=0
cost_anomaly_subscription_count=0
if check_result "$anomaly_monitors_file" || check_result "$anomaly_subs_file"; then
    cost_anomaly_collected="true"
fi
if check_result "$anomaly_monitors_file"; then
    cost_anomaly_monitor_count=$(jq '[.AnomalyMonitors[]?] | length' "$anomaly_monitors_file" 2>/dev/null || echo 0)
fi
if check_result "$anomaly_subs_file"; then
    cost_anomaly_subscription_count=$(jq '[.AnomalySubscriptions[]?] | length' "$anomaly_subs_file" 2>/dev/null || echo 0)
fi

# --- Cost allocation tags (FIN-UND-01, FIN-UND-03) ---
tags_file="$RAW_DATA_DIR/ce-list-cost-allocation-tags.json"
cost_tags_collected="false"
cost_tags_active_count=0
cost_tags_has_ai_tags="false"
if check_result "$tags_file"; then
    cost_tags_collected="true"
    cost_tags_active_count=$(jq '[.CostAllocationTags[]?] | length' "$tags_file" 2>/dev/null || echo 0)
    if jq -e '.CostAllocationTags[]? | select(.TagKey | test("ai|agent|bedrock|genai|ml"; "i"))' "$tags_file" >/dev/null 2>&1; then
        cost_tags_has_ai_tags="true"
    fi
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
    --argjson has_invocation_logging "$has_invocation_logging" \
    --argjson has_cost_data "$has_cost_data" \
    --argjson has_budgets "$has_budgets" \
    --argjson budgets_total_count "$budgets_total_count" \
    --argjson budgets_has_ai_budgets "$budgets_has_ai_budgets" \
    --argjson budgets_alert_count "$budgets_alert_count" \
    --argjson has_guardrail_prefiltering "$has_guardrail_prefiltering" \
    --argjson has_provisioned_throughput "$has_provisioned_throughput" \
    --argjson provisioned_throughput_count "$provisioned_throughput_count" \
    --arg agent_model_id "$agent_model_id" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson sagemaker_endpoints "$endpoints_json" \
    --argjson cost_anomaly_collected "$cost_anomaly_collected" \
    --argjson cost_anomaly_monitor_count "$cost_anomaly_monitor_count" \
    --argjson cost_anomaly_subscription_count "$cost_anomaly_subscription_count" \
    --argjson cost_tags_collected "$cost_tags_collected" \
    --argjson cost_tags_active_count "$cost_tags_active_count" \
    --argjson cost_tags_has_ai_tags "$cost_tags_has_ai_tags" \
    '{
        framework: "finops",
        timestamp: $timestamp,
        errors: $errors,
        understand: {
            has_invocation_logging: $has_invocation_logging,
            has_cost_data: $has_cost_data,
            has_budgets: $has_budgets,
            budgets: { total_count: $budgets_total_count, has_ai_budgets: $budgets_has_ai_budgets, alert_count: $budgets_alert_count },
            cost_allocation_tags: { collected: $cost_tags_collected, active_count: $cost_tags_active_count, has_ai_tags: $cost_tags_has_ai_tags }
        },
        optimize: {
            has_guardrail_prefiltering: $has_guardrail_prefiltering,
            has_provisioned_throughput: $has_provisioned_throughput,
            provisioned_throughput_count: $provisioned_throughput_count
        },
        cost_anomaly: { collected: $cost_anomaly_collected, monitor_count: $cost_anomaly_monitor_count, subscription_count: $cost_anomaly_subscription_count },
        agent: {model_id: $agent_model_id, idle_session_ttl: $agent_idle_ttl},
        sagemaker_endpoints: $sagemaker_endpoints
    }' > "$DATA_DIR/finops-summary.json"

progress "finops-summary.json written to ${DATA_DIR}/finops-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
