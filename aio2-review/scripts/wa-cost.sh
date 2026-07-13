#!/usr/bin/env bash
# wa-cost.sh — WA Cost pillar data collection for AIO2 review
#
# Usage:
#   wa-cost.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--guardrail-ids <id1,id2,...>] [--kb-ids <id1,id2,...>]
#     [--flow-ids <id1,id2,...>] [--endpoint-config-names <name1,name2,...>]
#     [--lambda-names <name1,name2,...>]
#
# Writes: $DATA_DIR/cost-summary.json
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
KB_IDS_RAW=""
FLOW_IDS_RAW=""
ENDPOINT_CONFIG_NAMES_RAW=""
LAMBDA_NAMES_RAW=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> --data-dir <path> [OPTIONS]

Options:
  --region <region>                  AWS region (required)
  --profile <profile>                AWS CLI profile name (optional)
  --data-dir <path>                  Data directory (required)
  --agent-id <id>                    Bedrock Agent ID (optional)
  --guardrail-ids <ids>              Comma-separated guardrail IDs (optional)
  --kb-ids <ids>                     Comma-separated Knowledge Base IDs (optional)
  --flow-ids <ids>                   Comma-separated Bedrock Flow IDs (optional)
  --endpoint-config-names <names>    Comma-separated SageMaker endpoint config names (optional)
  --lambda-names <names>             Comma-separated Lambda function names (optional)
  --help, -h                         Show this help message

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
        --endpoint-config-names)
            ENDPOINT_CONFIG_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --endpoint-config-names=*)
            ENDPOINT_CONFIG_NAMES_RAW="${1#--endpoint-config-names=}"
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

GUARDRAIL_IDS=()
if [ -n "$GUARDRAIL_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && GUARDRAIL_IDS+=("$item")
    done < <(split_csv "$GUARDRAIL_IDS_RAW")
fi

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

ENDPOINT_CONFIG_NAMES=()
if [ -n "$ENDPOINT_CONFIG_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && ENDPOINT_CONFIG_NAMES+=("$item")
    done < <(split_csv "$ENDPOINT_CONFIG_NAMES_RAW")
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
progress "Phase 1: Fetching cost data..."

# Agent fetches (if AGENT_ID set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json" \
        aws bedrock-agent list-agent-aliases --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    wait

    # Resolve the set of agent versions actually in use (aliased + DRAFT)
    # and fetch action groups for each. Querying only DRAFT misses what's
    # deployed when an alias routes to a numbered version.
    AGENT_VERSIONS=$(resolve_agent_versions "$AGENT_ID" "$RAW_DATA_DIR" \
        "$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json")
    while IFS= read -r _ag_ver; do
        [ -z "$_ag_ver" ] && continue
        fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-agent-action-groups-${_ag_ver}.json" \
            aws bedrock-agent list-agent-action-groups --agent-id "$AGENT_ID" \
                --agent-version "$_ag_ver" --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    done <<< "$AGENT_VERSIONS"
fi

# Fixed fetches
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json" \
    aws bedrock list-provisioned-model-throughputs \
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
    i=$((i + 1))
done

# Per-endpoint-config fetches
i=0
while [ "$i" -lt "${#ENDPOINT_CONFIG_NAMES[@]}" ]; do
    cfg_name="${ENDPOINT_CONFIG_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/sagemaker-describe-endpoint-config-${cfg_name}.json" \
        aws sagemaker describe-endpoint-config --endpoint-config-name "$cfg_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Build cost-summary.json
# ---------------------------------------------------------------------------
progress "Building cost-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Agent ---
agent_foundation_model="null"
agent_idle_ttl=0
agent_idle_ttl_ok="false"
agent_action_group_count=0

agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
if [ -n "$AGENT_ID" ] && check_result "$agent_file"; then
    agent_foundation_model=$(jq -r '.agent.foundationModel // "unknown"' "$agent_file" 2>/dev/null || echo "unknown")
    agent_idle_ttl=$(jq -r '.agent.idleSessionTTLInSeconds // 0' "$agent_file" 2>/dev/null || echo 0)
    if [ "$agent_idle_ttl" -lt 3600 ] 2>/dev/null; then
        agent_idle_ttl_ok="true"
    fi
fi

ag_file="$RAW_DATA_DIR/bedrock-agent-list-agent-action-groups.json"
if [ -n "$AGENT_ID" ] && check_result "$ag_file"; then
    agent_action_group_count=$(jq '.actionGroupSummaries | length' "$ag_file" 2>/dev/null || echo 0)
else
    # Per-version files from discover-resources: pick the max count across
    # versions so we report action groups that exist in any version actually
    # in use (aliased versions + DRAFT).
    for _ag_per_ver_file in "$RAW_DATA_DIR"/bedrock-agent-list-agent-action-groups-*.json; do
        [ -f "$_ag_per_ver_file" ] || continue
        check_result "$_ag_per_ver_file" || continue
        _ver_count=$(jq '.actionGroupSummaries | length' "$_ag_per_ver_file" 2>/dev/null || echo 0)
        if [ "$_ver_count" -gt "${agent_action_group_count:-0}" ] 2>/dev/null; then
            agent_action_group_count="$_ver_count"
        fi
    done
fi

# --- Guardrails ---
guardrail_parts=""
i=0
while [ "$i" -lt "${#GUARDRAIL_IDS[@]}" ]; do
    gid="${GUARDRAIL_IDS[$i]}"
    gid_safe=$(safe_id "$gid")
    gfile="$RAW_DATA_DIR/bedrock-get-guardrail-${gid_safe}.json"
    has_content_prefiltering="false"

    if check_result "$gfile"; then
        filter_count=$(jq '(.contentPolicy.filters | length) // 0' "$gfile" 2>/dev/null || echo 0)
        if [ "$filter_count" -gt 0 ]; then
            has_content_prefiltering="true"
        fi
    fi

    entry=$(jq -cn \
        --arg id "$gid" \
        --argjson has_content_prefiltering "$has_content_prefiltering" \
        '{id: $id, has_content_prefiltering: $has_content_prefiltering}')

    if [ -n "$guardrail_parts" ]; then
        guardrail_parts="${guardrail_parts},${entry}"
    else
        guardrail_parts="${entry}"
    fi
    i=$((i + 1))
done
guardrails_json="[${guardrail_parts}]"

# --- Knowledge bases ---
kb_parts=""
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    vector_store_type="unknown"

    if check_result "$kb_file"; then
        vector_store_type=$(jq -r '.knowledgeBase.storageConfiguration.type // "unknown"' "$kb_file" 2>/dev/null || echo "unknown")
    fi

    entry=$(jq -cn \
        --arg id "$kb_id" \
        --arg vector_store_type "$vector_store_type" \
        '{id: $id, vector_store_type: $vector_store_type}')

    if [ -n "$kb_parts" ]; then
        kb_parts="${kb_parts},${entry}"
    else
        kb_parts="${entry}"
    fi
    i=$((i + 1))
done
kb_json="[${kb_parts}]"

# --- Flows ---
flow_parts=""
i=0
while [ "$i" -lt "${#FLOW_IDS[@]}" ]; do
    flow_id="${FLOW_IDS[$i]}"
    flow_id_safe=$(safe_id "$flow_id")
    flow_file="$RAW_DATA_DIR/bedrock-agent-get-flow-${flow_id_safe}.json"
    uses_different_model_sizes="false"

    if check_result "$flow_file"; then
        unique_model_count=$(jq '[.definition.nodes[]?.configuration?.prompt?.sourceConfiguration?.inline?.modelId // empty] | unique | length' "$flow_file" 2>/dev/null || echo 0)
        if [ "$unique_model_count" -gt 1 ] 2>/dev/null; then
            uses_different_model_sizes="true"
        fi
    fi

    entry=$(jq -cn \
        --arg id "$flow_id" \
        --argjson uses_different_model_sizes "$uses_different_model_sizes" \
        '{id: $id, uses_different_model_sizes: $uses_different_model_sizes}')

    if [ -n "$flow_parts" ]; then
        flow_parts="${flow_parts},${entry}"
    else
        flow_parts="${entry}"
    fi
    i=$((i + 1))
done
flows_json="[${flow_parts}]"

# --- SageMaker endpoint configs ---
cfg_parts=""
i=0
while [ "$i" -lt "${#ENDPOINT_CONFIG_NAMES[@]}" ]; do
    cfg_name="${ENDPOINT_CONFIG_NAMES[$i]}"
    cfg_file="$RAW_DATA_DIR/sagemaker-describe-endpoint-config-${cfg_name}.json"
    instance_type="unknown"

    if check_result "$cfg_file"; then
        instance_type=$(jq -r '.ProductionVariants[0].InstanceType // "unknown"' "$cfg_file" 2>/dev/null || echo "unknown")
    fi

    entry=$(jq -cn \
        --arg name "$cfg_name" \
        --arg instance_type "$instance_type" \
        '{name: $name, instance_type: $instance_type}')

    if [ -n "$cfg_parts" ]; then
        cfg_parts="${cfg_parts},${entry}"
    else
        cfg_parts="${entry}"
    fi
    i=$((i + 1))
done
ep_configs_json="[${cfg_parts}]"

# --- Provisioned throughput ---
pmt_file="$RAW_DATA_DIR/bedrock-list-provisioned-model-throughputs.json"
pmt_exists="false"
pmt_count=0
if check_result "$pmt_file"; then
    pmt_count=$(jq '.provisionedModelSummaries | length' "$pmt_file" 2>/dev/null || echo 0)
    if [ "$pmt_count" -gt 0 ] 2>/dev/null; then
        pmt_exists="true"
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
    --arg agent_foundation_model "$agent_foundation_model" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson agent_idle_ttl_ok "$agent_idle_ttl_ok" \
    --argjson agent_action_group_count "$agent_action_group_count" \
    --argjson guardrails "$guardrails_json" \
    --argjson knowledge_bases "$kb_json" \
    --argjson flows "$flows_json" \
    --argjson sagemaker_endpoint_configs "$ep_configs_json" \
    --argjson pmt_exists "$pmt_exists" \
    --argjson pmt_count "$pmt_count" \
    '{
        pillar: "cost",
        timestamp: $timestamp,
        errors: $errors,
        agent: {
            foundation_model: $agent_foundation_model,
            idle_session_ttl: $agent_idle_ttl,
            idle_session_ttl_ok: $agent_idle_ttl_ok,
            action_group_count: $agent_action_group_count
        },
        guardrails: $guardrails,
        knowledge_bases: $knowledge_bases,
        flows: $flows,
        sagemaker_endpoint_configs: $sagemaker_endpoint_configs,
        provisioned_throughput: {exists: $pmt_exists, count: $pmt_count}
    }' > "$DATA_DIR/cost-summary.json"

progress "cost-summary.json written to ${DATA_DIR}/cost-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
