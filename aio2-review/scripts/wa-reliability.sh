#!/usr/bin/env bash
# wa-reliability.sh — WA Reliability pillar data collection for AIO2 review
#
# Usage:
#   wa-reliability.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--kb-ids <id1,id2,...>]
#     [--flow-ids <id1,id2,...>] [--lambda-names <name1,name2,...>]
#
# Writes: $DATA_DIR/reliability-summary.json
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
KB_IDS_RAW=""
FLOW_IDS_RAW=""
LAMBDA_NAMES_RAW=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> --data-dir <path> [OPTIONS]

Options:
  --region <region>        AWS region (required)
  --profile <profile>      AWS CLI profile name (optional)
  --data-dir <path>        Data directory (required)
  --agent-id <id>          Bedrock Agent ID (optional)
  --kb-ids <ids>           Comma-separated Knowledge Base IDs (optional)
  --flow-ids <ids>         Comma-separated Bedrock Flow IDs (optional)
  --lambda-names <names>   Comma-separated Lambda function names (optional)
  --help, -h               Show this help message

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
        --kb-ids)
            KB_IDS_RAW="${2:-}"
            shift 2
            ;;
        --kb-ids=*)
            KB_IDS_RAW="${1#--kb-ids=}"
            shift
            ;;
        --flow-ids)
            FLOW_IDS_RAW="${2:-}"
            shift 2
            ;;
        --flow-ids=*)
            FLOW_IDS_RAW="${1#--flow-ids=}"
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

KB_IDS=()
if [ -n "$KB_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && KB_IDS+=("$item")
    done < <(split_csv "$KB_IDS_RAW")
fi

FLOW_IDS=()
if [ -n "$FLOW_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && FLOW_IDS+=("$item")
    done < <(split_csv "$FLOW_IDS_RAW")
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
progress "Phase 1: Fetching reliability data..."

# Agent fetches (only if AGENT_ID is set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json" \
        aws bedrock-agent list-agent-aliases --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

fetch_or_cache "$RAW_DATA_DIR/cloudwatch-describe-alarms.json" \
    aws cloudwatch describe-alarms --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json" \
    aws bedrock list-provisioned-model-throughputs \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Inference profiles — cross-region inference (GENREL05_BP01)
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-inference-profiles.json" \
    aws bedrock list-inference-profiles \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Per-KB fetches
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json" \
        aws bedrock-agent get-knowledge-base --knowledge-base-id "$kb_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-flow fetches
i=0
while [ "$i" -lt "${#FLOW_IDS[@]}" ]; do
    flow_id="${FLOW_IDS[$i]}"
    flow_id_safe=$(safe_id "$flow_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-flow-${flow_id_safe}.json" \
        aws bedrock-agent get-flow --flow-identifier "$flow_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-flow-aliases-${flow_id_safe}.json" \
        aws bedrock-agent list-flow-aliases --flow-identifier "$flow_id" \
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

# Step Functions (GENOPS02_BP03 — complex retry workflows)
fetch_or_cache "$RAW_DATA_DIR/stepfunctions-list-state-machines.json" \
    aws stepfunctions list-state-machines \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Route53 health checks (GENREL02_BP01, GENREL05_BP01 — failover)
fetch_or_cache "$RAW_DATA_DIR/route53-list-health-checks.json" \
    aws route53 list-health-checks \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Bedrock auto-scaling targets (GENREL05_BP01)
fetch_or_cache "$RAW_DATA_DIR/autoscaling-describe-scalable-targets-bedrock.json" \
    aws application-autoscaling describe-scalable-targets --service-namespace bedrock \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# API Gateway (GENOPS02_BP03, GENSEC04_BP02 — rate limiting)
fetch_or_cache "$RAW_DATA_DIR/apigateway-get-rest-apis.json" \
    aws apigateway get-rest-apis \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# VPC/subnet architecture (GENREL02_BP01 — network redundancy)
fetch_or_cache "$RAW_DATA_DIR/ec2-describe-vpcs.json" \
    aws ec2 describe-vpcs \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/ec2-describe-subnets.json" \
    aws ec2 describe-subnets \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Build reliability-summary.json
# ---------------------------------------------------------------------------
progress "Building reliability-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Agent ---
agent_has_aliases="false"
agent_alias_count=0
agent_idle_ttl="null"

agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
aliases_file="$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json"

if [ -n "$AGENT_ID" ]; then
    if check_result "$agent_file"; then
        raw_ttl=$(jq -r '.agent.idleSessionTTLInSeconds // empty' "$agent_file" 2>/dev/null || true)
        [ -n "$raw_ttl" ] && agent_idle_ttl="$raw_ttl"
    fi
    if check_result "$aliases_file"; then
        agent_alias_count=$(jq '.agentAliasSummaries | length' "$aliases_file" 2>/dev/null || echo 0)
        if [ "$agent_alias_count" -gt 0 ]; then
            agent_has_aliases="true"
        fi
    fi
fi

# --- Alarms ---
alarms_file="$RAW_DATA_DIR/cloudwatch-describe-alarms.json"
alarms_count=0
bedrock_alarm_count=0
if check_result "$alarms_file"; then
    alarms_count=$(jq '(.MetricAlarms | length) + (.CompositeAlarms | length)' "$alarms_file" 2>/dev/null || echo 0)
    bedrock_alarm_count=$(jq '[.MetricAlarms[]? | select(.Namespace | test("Bedrock"; "i"))] | length' "$alarms_file" 2>/dev/null || echo 0)
fi

# --- Provisioned throughput ---
pmt_file="$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json"
pmt_exists="false"
pmt_count=0
if check_result "$pmt_file"; then
    pmt_count=$(jq '.provisionedModelSummaries | length' "$pmt_file" 2>/dev/null || echo 0)
    if [ "$pmt_count" -gt 0 ]; then
        pmt_exists="true"
    fi
fi

# --- Knowledge bases ---
kb_parts=""
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    if check_result "$kb_file"; then
        kb_entry=$(jq -c --arg kb_id "$kb_id" '{
            id: $kb_id,
            status: (.knowledgeBase.status // "UNKNOWN"),
            storage_type: (.knowledgeBase.storageConfiguration.type // "UNKNOWN")
        }' "$kb_file" 2>/dev/null || echo "{\"id\":\"${kb_id}\",\"status\":\"UNKNOWN\",\"storage_type\":\"UNKNOWN\"}")
    else
        kb_entry="{\"id\":\"${kb_id}\",\"status\":\"UNKNOWN\",\"storage_type\":\"UNKNOWN\"}"
    fi
    if [ -n "$kb_parts" ]; then
        kb_parts="${kb_parts},${kb_entry}"
    else
        kb_parts="${kb_entry}"
    fi
    i=$((i + 1))
done
kb_json="[${kb_parts}]"

# --- Flows ---
flows_parts=""
i=0
while [ "$i" -lt "${#FLOW_IDS[@]}" ]; do
    flow_id="${FLOW_IDS[$i]}"
    flow_id_safe=$(safe_id "$flow_id")
    flow_aliases_file="$RAW_DATA_DIR/bedrock-agent-list-flow-aliases-${flow_id_safe}.json"
    flow_alias_count=0
    flow_has_aliases="false"
    if check_result "$flow_aliases_file"; then
        flow_alias_count=$(jq '.flowAliasSummaries | length' "$flow_aliases_file" 2>/dev/null || echo 0)
        if [ "$flow_alias_count" -gt 0 ]; then
            flow_has_aliases="true"
        fi
    fi
    flow_entry=$(jq -cn \
        --arg flow_id "$flow_id" \
        --argjson has_aliases "$flow_has_aliases" \
        --argjson alias_count "$flow_alias_count" \
        '{id: $flow_id, has_aliases: $has_aliases, alias_count: $alias_count}')
    if [ -n "$flows_parts" ]; then
        flows_parts="${flows_parts},${flow_entry}"
    else
        flows_parts="${flow_entry}"
    fi
    i=$((i + 1))
done
flows_json="[${flows_parts}]"

# --- Lambda functions ---
lambda_parts=""
i=0
while [ "$i" -lt "${#LAMBDA_NAMES[@]}" ]; do
    fn_name="${LAMBDA_NAMES[$i]}"
    fn_file="$RAW_DATA_DIR/lambda-get-function-configuration-${fn_name}.json"
    if check_result "$fn_file"; then
        fn_entry=$(jq -c --arg fn_name "$fn_name" '{
            name: $fn_name,
            timeout: (.Timeout // 0),
            memory: (.MemorySize // 0)
        }' "$fn_file" 2>/dev/null || echo "{\"name\":\"${fn_name}\",\"timeout\":0,\"memory\":0}")
    else
        fn_entry="{\"name\":\"${fn_name}\",\"timeout\":0,\"memory\":0}"
    fi
    if [ -n "$lambda_parts" ]; then
        lambda_parts="${lambda_parts},${fn_entry}"
    else
        lambda_parts="${fn_entry}"
    fi
    i=$((i + 1))
done
lambda_json="[${lambda_parts}]"

# --- Inference profiles (GENREL05_BP01 — cross-region inference) ---
ip_file="$RAW_DATA_DIR/bedrock-list-inference-profiles.json"
ip_system_count=0
ip_application_count=0
agent_uses_cross_region="false"
if check_result "$ip_file"; then
    ip_system_count=$(jq '[.inferenceProfileSummaries[]? | select(.type == "SYSTEM_DEFINED")] | length' "$ip_file" 2>/dev/null || echo 0)
    ip_application_count=$(jq '[.inferenceProfileSummaries[]? | select(.type == "APPLICATION")] | length' "$ip_file" 2>/dev/null || echo 0)
    # Check if the agent's model_id matches a cross-region inference profile ID
    if [ -n "$AGENT_ID" ] && check_result "$agent_file"; then
        agent_model=$(jq -r '.agent.foundationModel // ""' "$agent_file" 2>/dev/null || true)
        if [ -n "$agent_model" ]; then
            # Cross-region profile IDs start with a region prefix (e.g., "us.", "eu.")
            if echo "$agent_model" | grep -qE '^\w+\.' 2>/dev/null; then
                # Verify it matches an actual inference profile ID
                if jq -e --arg model "$agent_model" '.inferenceProfileSummaries[]? | select(.inferenceProfileId == $model)' "$ip_file" >/dev/null 2>&1; then
                    agent_uses_cross_region="true"
                fi
            fi
        fi
    fi
fi

# --- Step Functions (GENOPS02_BP03) ---
sfn_file="$RAW_DATA_DIR/stepfunctions-list-state-machines.json"
sfn_collected="false"
sfn_count=0
sfn_has_agent_related="false"
if check_result "$sfn_file"; then
    sfn_collected="true"
    sfn_count=$(jq '[.stateMachines[]?] | length' "$sfn_file" 2>/dev/null || echo 0)
    if jq -e '.stateMachines[]? | select(.name | test("bedrock|agent|genai|ai"; "i"))' "$sfn_file" >/dev/null 2>&1; then
        sfn_has_agent_related="true"
    fi
fi

# --- Route53 health checks (GENREL02_BP01) ---
r53_file="$RAW_DATA_DIR/route53-list-health-checks.json"
r53_collected="false"
r53_health_check_count=0
r53_has_failover="false"
if check_result "$r53_file"; then
    r53_collected="true"
    r53_health_check_count=$(jq '[.HealthChecks[]?] | length' "$r53_file" 2>/dev/null || echo 0)
    if jq -e '.HealthChecks[]? | select(.HealthCheckConfig.Type == "CALCULATED" or .HealthCheckConfig.Type == "CLOUDWATCH_METRIC")' "$r53_file" >/dev/null 2>&1; then
        r53_has_failover="true"
    fi
fi

# --- Auto-scaling (GENREL05_BP01) ---
as_file="$RAW_DATA_DIR/autoscaling-describe-scalable-targets-bedrock.json"
as_collected="false"
as_bedrock_targets_count=0
as_has_scaling_policies="false"
if check_result "$as_file"; then
    as_collected="true"
    as_bedrock_targets_count=$(jq '[.ScalableTargets[]?] | length' "$as_file" 2>/dev/null || echo 0)
    if [ "$as_bedrock_targets_count" -gt 0 ]; then
        as_has_scaling_policies="true"
    fi
fi

# --- API Gateway (rate limiting) ---
apigw_file="$RAW_DATA_DIR/apigateway-get-rest-apis.json"
apigw_collected="false"
apigw_rest_api_count=0
if check_result "$apigw_file"; then
    apigw_collected="true"
    apigw_rest_api_count=$(jq '[.items[]?] | length' "$apigw_file" 2>/dev/null || echo 0)
fi

# --- Network architecture (GENREL02_BP01) ---
vpc_file="$RAW_DATA_DIR/ec2-describe-vpcs.json"
subnet_file="$RAW_DATA_DIR/ec2-describe-subnets.json"
net_collected="false"
net_vpc_count=0
net_subnet_count=0
net_az_count=0
net_multi_az="false"
if check_result "$vpc_file" || check_result "$subnet_file"; then
    net_collected="true"
fi
if check_result "$vpc_file"; then
    net_vpc_count=$(jq '[.Vpcs[]?] | length' "$vpc_file" 2>/dev/null || echo 0)
fi
if check_result "$subnet_file"; then
    net_subnet_count=$(jq '[.Subnets[]?] | length' "$subnet_file" 2>/dev/null || echo 0)
    net_az_count=$(jq '[.Subnets[]?.AvailabilityZone] | unique | length' "$subnet_file" 2>/dev/null || echo 0)
    if [ "$net_az_count" -gt 1 ]; then
        net_multi_az="true"
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
    --argjson agent_has_aliases "$agent_has_aliases" \
    --argjson agent_alias_count "$agent_alias_count" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson alarms_count "$alarms_count" \
    --argjson bedrock_alarm_count "$bedrock_alarm_count" \
    --argjson pmt_exists "$pmt_exists" \
    --argjson pmt_count "$pmt_count" \
    --argjson ip_system_count "$ip_system_count" \
    --argjson ip_application_count "$ip_application_count" \
    --argjson agent_uses_cross_region "$agent_uses_cross_region" \
    --argjson knowledge_bases "$kb_json" \
    --argjson flows "$flows_json" \
    --argjson lambda_functions "$lambda_json" \
    --argjson sfn_collected "$sfn_collected" \
    --argjson sfn_count "$sfn_count" \
    --argjson sfn_has_agent_related "$sfn_has_agent_related" \
    --argjson r53_collected "$r53_collected" \
    --argjson r53_health_check_count "$r53_health_check_count" \
    --argjson r53_has_failover "$r53_has_failover" \
    --argjson as_collected "$as_collected" \
    --argjson as_bedrock_targets_count "$as_bedrock_targets_count" \
    --argjson as_has_scaling_policies "$as_has_scaling_policies" \
    --argjson apigw_collected "$apigw_collected" \
    --argjson apigw_rest_api_count "$apigw_rest_api_count" \
    --argjson net_collected "$net_collected" \
    --argjson net_vpc_count "$net_vpc_count" \
    --argjson net_subnet_count "$net_subnet_count" \
    --argjson net_az_count "$net_az_count" \
    --argjson net_multi_az "$net_multi_az" \
    '{
        pillar: "reliability",
        timestamp: $timestamp,
        errors: $errors,
        agent: {
            has_aliases: $agent_has_aliases,
            alias_count: $agent_alias_count,
            idle_session_ttl: $agent_idle_ttl
        },
        alarms: {
            count: $alarms_count,
            bedrock_alarm_count: $bedrock_alarm_count
        },
        provisioned_throughput: {
            exists: $pmt_exists,
            count: $pmt_count
        },
        inference_profiles: {
            system_defined_count: $ip_system_count,
            application_count: $ip_application_count,
            agent_uses_cross_region: $agent_uses_cross_region
        },
        knowledge_bases: $knowledge_bases,
        flows: $flows,
        lambda_functions: $lambda_functions,
        step_functions: {
            collected: $sfn_collected,
            count: $sfn_count,
            has_agent_related: $sfn_has_agent_related
        },
        route53: {
            collected: $r53_collected,
            health_check_count: $r53_health_check_count,
            has_failover: $r53_has_failover
        },
        autoscaling: {
            collected: $as_collected,
            bedrock_targets_count: $as_bedrock_targets_count,
            has_scaling_policies: $as_has_scaling_policies
        },
        api_gateway: {
            collected: $apigw_collected,
            rest_api_count: $apigw_rest_api_count
        },
        network: {
            collected: $net_collected,
            vpc_count: $net_vpc_count,
            subnet_count: $net_subnet_count,
            az_count: $net_az_count,
            multi_az: $net_multi_az
        }
    }' > "$DATA_DIR/reliability-summary.json"

progress "reliability-summary.json written to ${DATA_DIR}/reliability-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
