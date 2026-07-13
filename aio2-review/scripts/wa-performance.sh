#!/usr/bin/env bash
# wa-performance.sh — WA Performance pillar data collection for AIO2 review
#
# Usage:
#   wa-performance.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--kb-ids <id1,id2,...>] [--flow-ids <id1,id2,...>]
#     [--endpoint-names <name1,name2,...>] [--endpoint-config-names <name1,name2,...>]
#     [--lambda-names <name1,name2,...>]
#
# Writes: $DATA_DIR/performance-summary.json
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
ENDPOINT_NAMES_RAW=""
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
  --kb-ids <ids>                     Comma-separated Knowledge Base IDs (optional)
  --flow-ids <ids>                   Comma-separated Bedrock Flow IDs (optional)
  --endpoint-names <names>           Comma-separated SageMaker endpoint names (optional)
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
        --endpoint-names)
            ENDPOINT_NAMES_RAW="${2:-}"
            shift 2
            ;;
        --endpoint-names=*)
            ENDPOINT_NAMES_RAW="${1#--endpoint-names=}"
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

ENDPOINT_NAMES=()
if [ -n "$ENDPOINT_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && ENDPOINT_NAMES+=("$item")
    done < <(split_csv "$ENDPOINT_NAMES_RAW")
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
progress "Phase 1: Fetching performance data..."

# Agent fetch (if AGENT_ID set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

# Per-KB fetches
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json" \
        aws bedrock-agent get-knowledge-base --knowledge-base-id "$kb_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json" \
        aws bedrock-agent list-data-sources --knowledge-base-id "$kb_id" \
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

# Per-endpoint fetches
i=0
while [ "$i" -lt "${#ENDPOINT_NAMES[@]}" ]; do
    ep_name="${ENDPOINT_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/sagemaker-describe-endpoint-${ep_name}.json" \
        aws sagemaker describe-endpoint --endpoint-name "$ep_name" \
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

# Per-lambda fetches
i=0
while [ "$i" -lt "${#LAMBDA_NAMES[@]}" ]; do
    fn_name="${LAMBDA_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/lambda-get-function-configuration-${fn_name}.json" \
        aws lambda get-function-configuration --function-name "$fn_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Foundation model listing (GENPERF02_BP03, GENCOST01_BP01 — model selection)
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-foundation-models.json" \
    aws bedrock list-foundation-models \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# MLflow tracking servers (GENPERF01_BP02 — experiment tracking)
fetch_or_cache "$RAW_DATA_DIR/sagemaker-list-mlflow-tracking-servers.json" \
    aws sagemaker list-mlflow-tracking-servers \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Model customization jobs (GENPERF02_BP03, GENSUS03_BP01 — distillation/fine-tuning)
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-model-customization-jobs.json" \
    aws bedrock list-model-customization-jobs \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Build performance-summary.json
# ---------------------------------------------------------------------------
progress "Building performance-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Agent ---
agent_model_id="null"
agent_idle_ttl="null"
agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
if [ -n "$AGENT_ID" ] && check_result "$agent_file"; then
    agent_model_id=$(jq -r '.agent.foundationModel // "unknown"' "$agent_file" 2>/dev/null || echo "unknown")
    agent_idle_ttl=$(jq -r '.agent.idleSessionTTLInSeconds // 0' "$agent_file" 2>/dev/null || echo 0)
fi

# --- Knowledge bases ---
kb_parts=""
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    storage_type="unknown"
    embedding_model="unknown"
    vector_dimensions=0
    chunking_strategy="unknown"

    if check_result "$kb_file"; then
        storage_type=$(jq -r '.knowledgeBase.storageConfiguration.type // "unknown"' "$kb_file" 2>/dev/null || echo "unknown")
        embedding_model=$(jq -r '.knowledgeBase.knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration.embeddingModelArn // "unknown"' "$kb_file" 2>/dev/null || echo "unknown")
        vector_dimensions=$(jq -r '.knowledgeBase.knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration.embeddingModelConfiguration.bedrockEmbeddingModelConfiguration.dimensions // 0' "$kb_file" 2>/dev/null || echo 0)
    fi

    # Chunking strategy from data sources list
    ds_file="$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json"
    if check_result "$ds_file"; then
        chunking_strategy=$(jq -r '.dataSourceSummaries[0].dataDeletionPolicy // "unknown"' "$ds_file" 2>/dev/null || echo "unknown")
        # Try to get chunking strategy from the data source config
        cs=$(jq -r '(.dataSourceSummaries[0] | .description) // "unknown"' "$ds_file" 2>/dev/null || echo "unknown")
        if [ "$cs" != "unknown" ] && [ "$cs" != "null" ]; then
            chunking_strategy="$cs"
        fi
    fi

    entry=$(jq -cn \
        --arg id "$kb_id" \
        --arg storage_type "$storage_type" \
        --arg embedding_model "$embedding_model" \
        --argjson vector_dimensions "$vector_dimensions" \
        --arg chunking_strategy "$chunking_strategy" \
        '{id: $id, storage_type: $storage_type, embedding_model: $embedding_model, vector_dimensions: $vector_dimensions, chunking_strategy: $chunking_strategy}')

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
    node_count=0
    model_ids_json="[]"

    if check_result "$flow_file"; then
        node_count=$(jq '.definition.nodes | length' "$flow_file" 2>/dev/null || echo 0)
        model_ids_json=$(jq -c '[.definition.nodes[]?.configuration?.prompt?.sourceConfiguration?.inline?.modelId // empty] | unique' "$flow_file" 2>/dev/null || echo "[]")
    fi

    entry=$(jq -cn \
        --arg id "$flow_id" \
        --argjson node_count "$node_count" \
        --argjson model_ids "$model_ids_json" \
        '{id: $id, node_count: $node_count, model_ids: $model_ids}')

    if [ -n "$flow_parts" ]; then
        flow_parts="${flow_parts},${entry}"
    else
        flow_parts="${entry}"
    fi
    i=$((i + 1))
done
flows_json="[${flow_parts}]"

# --- SageMaker endpoints ---
ep_parts=""
i=0
while [ "$i" -lt "${#ENDPOINT_NAMES[@]}" ]; do
    ep_name="${ENDPOINT_NAMES[$i]}"
    ep_file="$RAW_DATA_DIR/sagemaker-describe-endpoint-${ep_name}.json"
    instance_type="unknown"
    autoscaling_configured="false"

    if check_result "$ep_file"; then
        # Instance type comes from the endpoint config; describe-endpoint gives ProductionVariants
        instance_type=$(jq -r '.ProductionVariants[0].CurrentInstanceType // "unknown"' "$ep_file" 2>/dev/null || echo "unknown")
    fi

    # Check endpoint config for instance type if not found above
    cfg_file="$RAW_DATA_DIR/sagemaker-describe-endpoint-config-${ep_name}.json"
    if [ "$instance_type" = "unknown" ] && check_result "$cfg_file"; then
        instance_type=$(jq -r '.ProductionVariants[0].InstanceType // "unknown"' "$cfg_file" 2>/dev/null || echo "unknown")
    fi

    entry=$(jq -cn \
        --arg name "$ep_name" \
        --arg instance_type "$instance_type" \
        --argjson autoscaling_configured "$autoscaling_configured" \
        '{name: $name, instance_type: $instance_type, autoscaling_configured: $autoscaling_configured}')

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
    timeout=0
    memory=0

    if check_result "$fn_file"; then
        timeout=$(jq -r '.Timeout // 0' "$fn_file" 2>/dev/null || echo 0)
        memory=$(jq -r '.MemorySize // 0' "$fn_file" 2>/dev/null || echo 0)
    fi

    entry=$(jq -cn \
        --arg name "$fn_name" \
        --argjson timeout "$timeout" \
        --argjson memory "$memory" \
        '{name: $name, timeout: $timeout, memory: $memory}')

    if [ -n "$lambda_parts" ]; then
        lambda_parts="${lambda_parts},${entry}"
    else
        lambda_parts="${entry}"
    fi
    i=$((i + 1))
done
lambda_json="[${lambda_parts}]"

# --- Foundation models (GENPERF02_BP03) ---
fm_file="$RAW_DATA_DIR/bedrock-list-foundation-models.json"
fm_collected="false"
fm_available_count=0
fm_providers="[]"
if check_result "$fm_file"; then
    fm_collected="true"
    fm_available_count=$(jq '[.modelSummaries[]?] | length' "$fm_file" 2>/dev/null || echo 0)
    fm_providers=$(jq '[.modelSummaries[]?.providerName] | unique' "$fm_file" 2>/dev/null || echo "[]")
fi

# --- MLflow (GENPERF01_BP02) ---
mlflow_file="$RAW_DATA_DIR/sagemaker-list-mlflow-tracking-servers.json"
mlflow_collected="false"
mlflow_tracking_server_count=0
if check_result "$mlflow_file"; then
    mlflow_collected="true"
    mlflow_tracking_server_count=$(jq '[.TrackingServers[]?] | length' "$mlflow_file" 2>/dev/null || echo 0)
fi

# --- Model customization (GENPERF02_BP03, GENSUS03_BP01) ---
mc_file="$RAW_DATA_DIR/bedrock-list-model-customization-jobs.json"
mc_collected="false"
mc_job_count=0
mc_has_distillation="false"
if check_result "$mc_file"; then
    mc_collected="true"
    mc_job_count=$(jq '[.modelCustomizationJobSummaries[]?] | length' "$mc_file" 2>/dev/null || echo 0)
    if jq -e '.modelCustomizationJobSummaries[]? | select(.customizationType == "DISTILLATION")' "$mc_file" >/dev/null 2>&1; then
        mc_has_distillation="true"
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
    --arg agent_model_id "$agent_model_id" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson knowledge_bases "$kb_json" \
    --argjson flows "$flows_json" \
    --argjson sagemaker_endpoints "$endpoints_json" \
    --argjson lambda_functions "$lambda_json" \
    --argjson fm_collected "$fm_collected" \
    --argjson fm_available_count "$fm_available_count" \
    --argjson fm_providers "$fm_providers" \
    --argjson mlflow_collected "$mlflow_collected" \
    --argjson mlflow_tracking_server_count "$mlflow_tracking_server_count" \
    --argjson mc_collected "$mc_collected" \
    --argjson mc_job_count "$mc_job_count" \
    --argjson mc_has_distillation "$mc_has_distillation" \
    '{
        pillar: "performance",
        timestamp: $timestamp,
        errors: $errors,
        agent: {model_id: $agent_model_id, idle_session_ttl: $agent_idle_ttl},
        knowledge_bases: $knowledge_bases,
        flows: $flows,
        sagemaker_endpoints: $sagemaker_endpoints,
        lambda_functions: $lambda_functions,
        foundation_models: {
            collected: $fm_collected,
            available_count: $fm_available_count,
            providers: $fm_providers
        },
        mlflow: {
            collected: $mlflow_collected,
            tracking_server_count: $mlflow_tracking_server_count
        },
        model_customization: {
            collected: $mc_collected,
            job_count: $mc_job_count,
            has_distillation: $mc_has_distillation
        }
    }' > "$DATA_DIR/performance-summary.json"

progress "performance-summary.json written to ${DATA_DIR}/performance-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
