#!/usr/bin/env bash
# discover-resources.sh — Discover GenAI resources from Agent ARN, CloudFormation stack,
# or AppRegistry application. Creates a data directory with a data/ subdirectory,
# writes raw JSON to data/, writes manifest.json and report.json skeleton to the
# data directory root, and outputs the data directory path as the last stdout line.
#
# Usage:
#   discover-resources.sh --region <region> [--profile <profile>]
#     [--agent-arn <arn>] [--stack-name <name>] [--app-arn <arn>]
#     [--solution-name <name>] [--frameworks <list>] [--data-dir <path>]
#     [--help]
#
# Output (stdout): progress lines prefixed ">>" and the data directory path (last line)
# Output (data dir root): manifest.json, report.json
# Output (data/):         *.json raw API outputs
#
# Exit codes:
#   0 — full success
#   1 — fatal error (missing deps, invalid args, credential failure)
#   2 — partial success (some commands failed, errors collected)
#   3 — scoped discovery yielded zero resources; halt before assessment
#   4 — authorization error on a required API call; halt and wait for resolution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

# ---------------------------------------------------------------------------
# Script-specific globals
# ---------------------------------------------------------------------------
AGENT_ARN=""
STACK_NAME=""
APP_ARN=""
TF_STATE_DIR=""
RESOURCE_GROUP=""
SOLUTION_NAME=""
FRAMEWORKS="wa"
REVIEW_SCOPE=""

# Resource ID arrays (bash 3.2 compatible — no declare -A)
AGENT_IDS=()
KB_IDS=()
GUARDRAIL_IDS=()
FLOW_IDS=()
ROLE_NAMES=()
ENDPOINT_NAMES=()
ENDPOINT_CONFIG_NAMES=()
TRAIL_ARNS=()
USER_POOL_IDS=()
CUSTOM_MODEL_IDS=()
LAMBDA_NAMES=()
MODELS=()

AGENTCORE_RUNTIME_IDS=()
AGENTCORE_GATEWAY_IDS=()
AGENTCORE_IDENTITY_IDS=()
AGENTCORE_MEMORY_IDS=()
PROMPT_IDS=()

INFERENCE_PROFILES=()
MODELS_NEEDING_RESOLUTION=()
AGENTCORE_RUNTIME_MODELS=()
BEDROCK_AGENT_MODELS=()

ACCOUNT_ID=""
IDENTITY_ARN=""
INPUT_TYPE="code-only"

# CLI version miss tracking — serialized into manifest's "errors" array
AGENTCORE_CLI_ERRORS=()

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> [OPTIONS]

Options:
  --region <region>        AWS region (required)
  --profile <profile>      AWS CLI profile name (optional)
  --agent-arn <arn>        Bedrock Agent ARN (Option A)
  --stack-name <name>      CloudFormation stack name (Option B - CFN)
  --tf-state-dir <path>   Terraform project directory (Option B - Terraform)
                           Runs "terraform state pull" in this directory
  --app-arn <arn>          AppRegistry application ARN (Option C)
  --resource-group <arn>   AWS Resource Group ARN (Option D)
  --solution-name <name>   Human-readable solution name (default: "solution")
  --frameworks <list>      Comma-separated frameworks: wa,nist,finops (default: wa)
  --review-scope <scope>   "Code Review", "Cloud Review", or "Full Review"
                           (recorded in manifest.json and report.json metadata)
  --data-dir <path>        Use existing data directory instead of creating one
  --help, -h               Show this help message

Exit codes:
  0  Full success
  1  Fatal error (missing deps, invalid args, credential failure)
  2  Partial success (some commands failed)
  3  Scoped discovery yielded zero resources; halt before assessment
  4  Authorization error on a required API call; halt and wait for resolution
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
        --agent-arn)
            AGENT_ARN="${2:-}"
            shift 2
            ;;
        --agent-arn=*)
            AGENT_ARN="${1#--agent-arn=}"
            shift
            ;;
        --stack-name)
            STACK_NAME="${2:-}"
            shift 2
            ;;
        --stack-name=*)
            STACK_NAME="${1#--stack-name=}"
            shift
            ;;
        --tf-state-dir)
            TF_STATE_DIR="${2:-}"
            shift 2
            ;;
        --tf-state-dir=*)
            TF_STATE_DIR="${1#--tf-state-dir=}"
            shift
            ;;
        --app-arn)
            APP_ARN="${2:-}"
            shift 2
            ;;
        --app-arn=*)
            APP_ARN="${1#--app-arn=}"
            shift
            ;;
        --resource-group)
            RESOURCE_GROUP="${2:-}"
            shift 2
            ;;
        --resource-group=*)
            RESOURCE_GROUP="${1#--resource-group=}"
            shift
            ;;
        --solution-name)
            SOLUTION_NAME="${2:-}"
            shift 2
            ;;
        --solution-name=*)
            SOLUTION_NAME="${1#--solution-name=}"
            shift
            ;;
        --frameworks)
            FRAMEWORKS="${2:-wa}"
            shift 2
            ;;
        --frameworks=*)
            FRAMEWORKS="${1#--frameworks=}"
            shift
            ;;
        --review-scope)
            REVIEW_SCOPE="${2:-}"
            shift 2
            ;;
        --review-scope=*)
            REVIEW_SCOPE="${1#--review-scope=}"
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

# Default solution name
if [ -z "$SOLUTION_NAME" ]; then
    SOLUTION_NAME="solution"
fi

# Validate review scope (closed set per references/report-schema.md). Empty
# is allowed for backwards compatibility — orchestrator can still set it via
# set-narrative.sh later, but every new invocation should pass --review-scope.
if [ -n "$REVIEW_SCOPE" ]; then
    case "$REVIEW_SCOPE" in
        "Code Review"|"Cloud Review"|"Full Review")
            ;;
        *)
            echo "ERROR: --review-scope must be one of: 'Code Review', 'Cloud Review', 'Full Review' (got '${REVIEW_SCOPE}')" >&2
            exit 1
            ;;
    esac
fi

# Sanitize solution name for use in directory name (replace spaces/special chars)
SOLUTION_SLUG=$(echo "$SOLUTION_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

# ---------------------------------------------------------------------------
# Credential validation
# ---------------------------------------------------------------------------
progress "Validating AWS credentials..."
validate_aws_credentials
ACCOUNT_ID="$VALIDATED_ACCOUNT_ID"
IDENTITY_ARN="$VALIDATED_IDENTITY_ARN"

# ---------------------------------------------------------------------------
# Create data directory
# ---------------------------------------------------------------------------
DISCOVERY_DATE=$(date '+%Y-%m-%d')

if [ -z "$DATA_DIR" ]; then
    DATA_DIR="aio2-data-${SOLUTION_SLUG}-${DISCOVERY_DATE}"
    mkdir -p "$DATA_DIR"
    log_info "Created data directory: ${DATA_DIR}"
fi

# validate_data_dir sets RAW_DATA_DIR and creates data/ subdirectory
validate_data_dir

# Write sts identity to raw data dir for traceability
aws sts get-caller-identity --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json \
    > "$RAW_DATA_DIR/sts-get-caller-identity.json" 2>/dev/null || true


# ---------------------------------------------------------------------------
# Helper: extract Lambda names from action groups JSON
# ---------------------------------------------------------------------------
extract_lambda_names_from_action_groups() {
    local ag_file="$1"
    if check_result "$ag_file"; then
        # Extract Lambda function names from actionGroupExecutor.lambda fields
        local names
        names=$(jq -r '
            .actionGroupSummaries[]?
            | select(.actionGroupExecutor.lambda? != null)
            | .actionGroupExecutor.lambda
            | split(":")[-1]
            | split("/")[-1]
        ' "$ag_file" 2>/dev/null || true)
        if [ -n "$names" ]; then
            while IFS= read -r name; do
                [ -n "$name" ] && LAMBDA_NAMES+=("$name")
            done <<< "$names"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Helper: fetch a resource family with CLI version check
# ---------------------------------------------------------------------------
# Wraps an AWS CLI invocation for new resource families. Detects CLI version
# misses (Invalid choice, command not found, argument operation: Invalid choice)
# and handles them gracefully:
#   - On CLI version miss: log_warn, record in AGENTCORE_CLI_ERRORS, write
#     "null" to the cache file, return 0 (non-fatal).
#   - On any other non-zero exit: fall through to retry_cmd non-retryable
#     error handling via fetch_or_cache.
#   - On success: write output to the cache file.
#
# Usage: fetch_family_with_cli_check <out_file> <family_name> <cmd...>
#   out_file   — path to write the JSON output (or "null" on CLI miss)
#   family     — human-readable family name for diagnostics
#   cmd...     — the full AWS CLI command to execute
#
# Requirements: 3.8
fetch_family_with_cli_check() {
    local out_file="$1" family="$2"; shift 2

    # If cache already has valid data, skip the fetch.
    if [ -f "$out_file" ] && [ -s "$out_file" ]; then
        local existing
        existing=$(cat "$out_file")
        if [ "$existing" != "null" ] && echo "$existing" | jq empty >/dev/null 2>&1; then
            log_info "Cache hit: ${out_file}"
            return 0
        fi
    fi

    local output rc
    set +e
    output=$("$@" 2>&1)
    rc=$?
    set -e

    if [ "$rc" -ne 0 ] && echo "$output" | grep -qE 'Invalid choice|command not found|argument operation: Invalid choice'; then
        log_warn "AWS CLI does not support ${family} ($(echo "$*" | sed 's/ --output json//;s/ --region [^ ]*//')); skipping"
        # Record for manifest errors array: "family|operation|message"
        local operation
        operation=$(echo "$*" | awk '{for(i=1;i<=NF;i++){if($i ~ /^(list|get|describe)-/){print $i; exit}}}')
        AGENTCORE_CLI_ERRORS+=("${family}|${operation}|AWS CLI does not support this operation")
        echo "null" > "$out_file"
        return 0
    fi

    if [ "$rc" -ne 0 ]; then
        # Not a CLI version miss — defer to existing fetch_or_cache which
        # handles retries and non-retryable error recording.
        fetch_or_cache "$out_file" "$@"
        return 0
    fi

    # Success — validate and write output
    if [ -n "$output" ] && echo "$output" | jq empty >/dev/null 2>&1; then
        echo "$output" > "$out_file"
        log_info "Fetched and cached: ${out_file}"
    else
        echo "null" > "$out_file"
        record_error "Invalid JSON output for ${out_file}: ${output}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Discovery path A: Agent ARN
# ---------------------------------------------------------------------------
discover_agent_arn() {
    progress "Discovering resources from Agent ARN..."

    INPUT_TYPE="agent-arn"

    # Extract agent ID from ARN (last path component)
    local agent_id
    agent_id="${AGENT_ARN##*/}"

    # Extract account from ARN (field 5, colon-delimited)
    ACCOUNT_ID=$(echo "$AGENT_ARN" | cut -d: -f5)

    log_info "Agent ID: ${agent_id}"

    # get-agent
    local agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
    fetch_or_cache "$agent_file" \
        aws bedrock-agent get-agent --agent-id "$agent_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$agent_file"; then
        local role_arn model_id agent_name role_name
        role_arn=$(jq -r '.agent.agentResourceRoleArn // empty' "$agent_file" 2>/dev/null || true)
        model_id=$(jq -r '.agent.foundationModel // empty' "$agent_file" 2>/dev/null || true)
        agent_name=$(jq -r '.agent.agentName // empty' "$agent_file" 2>/dev/null || true)

        AGENT_IDS+=("$agent_id")

        # Resolve foundation model through inference-profile chain (R3.1, R3.3)
        if [ -n "$model_id" ]; then
            local resolved
            set +e
            resolved=$(resolve_component_model "$model_id" "$model_id")
            local rc=$?
            set -e
            if [ "$rc" -eq 0 ] && [ -n "$resolved" ]; then
                local resolved_model
                resolved_model=$(printf '%s' "$resolved" | cut -d'|' -f1)
                [ -n "$resolved_model" ] && MODELS+=("$resolved_model")
                BEDROCK_AGENT_MODELS+=("${agent_id}|${resolved}")
            else
                MODELS_NEEDING_RESOLUTION+=("$agent_id")
            fi
        fi

        if [ -n "$role_arn" ]; then
            role_name="${role_arn##*/}"
            [ -n "$role_name" ] && ROLE_NAMES+=("$role_name")
        fi
        log_info "Agent: ${agent_name}, Model: ${model_id}, Role: ${role_arn}"
    fi

    # Resolve the set of agent versions actually in use (aliased versions +
    # DRAFT). Querying only DRAFT can miss what's deployed when an alias
    # routes to a numbered version (e.g. "1").
    local versions
    versions=$(resolve_agent_versions "$agent_id" "$RAW_DATA_DIR" \
        "$RAW_DATA_DIR/bedrock-agent-list-agent-aliases.json")
    log_info "Agent versions to query: $(echo "$versions" | tr '\n' ' ')"

    # list-agent-knowledge-bases — per version, merged into KB_IDS
    while IFS= read -r ver; do
        [ -z "$ver" ] && continue
        local kb_file="$RAW_DATA_DIR/bedrock-agent-list-agent-knowledge-bases-${ver}.json"
        fetch_or_cache "$kb_file" \
            aws bedrock-agent list-agent-knowledge-bases \
                --agent-id "$agent_id" --agent-version "$ver" \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$kb_file"; then
            local kb_ids_raw
            kb_ids_raw=$(jq -r '.agentKnowledgeBaseSummaries[]?.knowledgeBaseId // empty' "$kb_file" 2>/dev/null || true)
            while IFS= read -r kb_id; do
                [ -n "$kb_id" ] && KB_IDS+=("$kb_id")
            done <<< "$kb_ids_raw"
        fi
    done <<< "$versions"

    # list-agent-action-groups — per version, each cached to its own file so
    # downstream scripts can inspect them individually.
    while IFS= read -r ver; do
        [ -z "$ver" ] && continue
        local ag_file="$RAW_DATA_DIR/bedrock-agent-list-agent-action-groups-${ver}.json"
        fetch_or_cache "$ag_file" \
            aws bedrock-agent list-agent-action-groups \
                --agent-id "$agent_id" --agent-version "$ver" \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        extract_lambda_names_from_action_groups "$ag_file"
    done <<< "$versions"

    # list-guardrails
    local gr_file="$RAW_DATA_DIR/bedrock-list-guardrails.json"
    fetch_or_cache "$gr_file" \
        aws bedrock list-guardrails \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$gr_file"; then
        local gr_ids_raw
        gr_ids_raw=$(jq -r '.guardrails[]?.guardrailId // empty' "$gr_file" 2>/dev/null || true)
        while IFS= read -r gr_id; do
            [ -n "$gr_id" ] && GUARDRAIL_IDS+=("$gr_id")
        done <<< "$gr_ids_raw"
    fi

    # list-flows
    local flows_file="$RAW_DATA_DIR/bedrock-agent-list-flows.json"
    fetch_or_cache "$flows_file" \
        aws bedrock-agent list-flows \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$flows_file"; then
        local flow_ids_raw
        flow_ids_raw=$(jq -r '.flowSummaries[]?.id // empty' "$flows_file" 2>/dev/null || true)
        while IFS= read -r flow_id; do
            [ -n "$flow_id" ] && FLOW_IDS+=("$flow_id")
        done <<< "$flow_ids_raw"
    fi

    # cloudtrail describe-trails
    local ct_file="$RAW_DATA_DIR/cloudtrail-describe-trails.json"
    fetch_or_cache "$ct_file" \
        aws cloudtrail describe-trails \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ct_file"; then
        local trail_arns_raw
        trail_arns_raw=$(jq -r '.trailList[]?.TrailARN // empty' "$ct_file" 2>/dev/null || true)
        while IFS= read -r trail_arn; do
            [ -n "$trail_arn" ] && TRAIL_ARNS+=("$trail_arn")
        done <<< "$trail_arns_raw"
    fi

    # cognito list-user-pools
    local cognito_file="$RAW_DATA_DIR/cognito-list-user-pools.json"
    fetch_or_cache "$cognito_file" \
        aws cognito-idp list-user-pools --max-results 10 \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$cognito_file"; then
        local pool_ids_raw
        pool_ids_raw=$(jq -r '.UserPools[]?.Id // empty' "$cognito_file" 2>/dev/null || true)
        while IFS= read -r pool_id; do
            [ -n "$pool_id" ] && USER_POOL_IDS+=("$pool_id")
        done <<< "$pool_ids_raw"
    fi

    # bedrock list-custom-models
    local cm_file="$RAW_DATA_DIR/bedrock-list-custom-models.json"
    fetch_or_cache "$cm_file" \
        aws bedrock list-custom-models \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$cm_file"; then
        local cm_ids_raw
        cm_ids_raw=$(jq -r '.modelSummaries[]?.modelArn // empty' "$cm_file" 2>/dev/null || true)
        while IFS= read -r cm_id; do
            [ -n "$cm_id" ] && CUSTOM_MODEL_IDS+=("$cm_id")
        done <<< "$cm_ids_raw"
    fi

    # sagemaker list-endpoints
    local sm_file="$RAW_DATA_DIR/sagemaker-list-endpoints.json"
    fetch_or_cache "$sm_file" \
        aws sagemaker list-endpoints \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$sm_file"; then
        local ep_names_raw
        ep_names_raw=$(jq -r '.Endpoints[]?.EndpointName // empty' "$sm_file" 2>/dev/null || true)
        while IFS= read -r ep_name; do
            [ -n "$ep_name" ] && ENDPOINT_NAMES+=("$ep_name")
        done <<< "$ep_names_raw"
    fi

    # --- AgentCore families (new CLI; use fetch_family_with_cli_check) ---

    # AgentCore Runtimes
    local ac_rt_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-agent-runtimes.json"
    fetch_family_with_cli_check "$ac_rt_file" "AgentCore Runtimes" \
        aws bedrock-agentcore-control list-agent-runtimes \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ac_rt_file"; then
        local ac_rt_ids_raw
        ac_rt_ids_raw=$(jq -r '.agentRuntimes[]?.agentRuntimeId // empty' "$ac_rt_file" 2>/dev/null || true)
        while IFS= read -r rt_id; do
            [ -n "$rt_id" ] && AGENTCORE_RUNTIME_IDS+=("$rt_id")
        done <<< "$ac_rt_ids_raw"
    fi

    # AgentCore Gateways
    local ac_gw_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-gateways.json"
    fetch_family_with_cli_check "$ac_gw_file" "AgentCore Gateways" \
        aws bedrock-agentcore-control list-gateways \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ac_gw_file"; then
        local ac_gw_ids_raw
        ac_gw_ids_raw=$(jq -r '.items[]?.gatewayId // empty' "$ac_gw_file" 2>/dev/null || true)
        while IFS= read -r gw_id; do
            [ -n "$gw_id" ] && AGENTCORE_GATEWAY_IDS+=("$gw_id")
        done <<< "$ac_gw_ids_raw"
    fi

    # AgentCore Workload Identities
    local ac_id_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-workload-identities.json"
    fetch_family_with_cli_check "$ac_id_file" "AgentCore Workload Identities" \
        aws bedrock-agentcore-control list-workload-identities \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ac_id_file"; then
        local ac_id_ids_raw
        ac_id_ids_raw=$(jq -r '.workloadIdentities[]?.name // empty' "$ac_id_file" 2>/dev/null || true)
        while IFS= read -r wid; do
            [ -n "$wid" ] && AGENTCORE_IDENTITY_IDS+=("$wid")
        done <<< "$ac_id_ids_raw"
    fi

    # AgentCore Memory stores
    local ac_mem_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-memories.json"
    fetch_family_with_cli_check "$ac_mem_file" "AgentCore Memory" \
        aws bedrock-agentcore-control list-memories \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ac_mem_file"; then
        local ac_mem_ids_raw
        ac_mem_ids_raw=$(jq -r '.memories[]?.memoryId // empty' "$ac_mem_file" 2>/dev/null || true)
        while IFS= read -r mem_id; do
            [ -n "$mem_id" ] && AGENTCORE_MEMORY_IDS+=("$mem_id")
        done <<< "$ac_mem_ids_raw"
    fi

    # Bedrock Prompt Management (established CLI; use regular fetch_or_cache)
    local prompts_file="$RAW_DATA_DIR/bedrock-agent-list-prompts.json"
    fetch_or_cache "$prompts_file" \
        aws bedrock-agent list-prompts \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$prompts_file"; then
        local prompt_ids_raw
        prompt_ids_raw=$(jq -r '.promptSummaries[]?.id // empty' "$prompts_file" 2>/dev/null || true)
        while IFS= read -r p_id; do
            [ -n "$p_id" ] && PROMPT_IDS+=("$p_id")
        done <<< "$prompt_ids_raw"
    fi
}


# ---------------------------------------------------------------------------
# Discovery path B: CloudFormation stack
# ---------------------------------------------------------------------------
discover_cfn_stack() {
    local stack_name="$1"
    progress "Discovering resources from CloudFormation stack: ${stack_name}..."

    # Sanitize stack name for use in filename (replace non-alphanumeric with dash)
    local safe_stack_name
    safe_stack_name="${stack_name//[^a-zA-Z0-9_-]/-}"

    # list-stack-resources (use stack-specific filename to avoid cache collisions)
    local resources_file="$RAW_DATA_DIR/cfn-list-stack-resources-${safe_stack_name}.json"
    fetch_or_cache "$resources_file" \
        aws cloudformation list-stack-resources \
            --stack-name "$stack_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    # get-template (use stack-specific filename to avoid cache collisions)
    local template_file="$RAW_DATA_DIR/cfn-get-template-${safe_stack_name}.json"
    fetch_or_cache "$template_file" \
        aws cloudformation get-template \
            --stack-name "$stack_name" \
            --template-stage Original \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
            --query TemplateBody --output json

    if ! check_result "$resources_file"; then
        log_warn "CloudFormation list-stack-resources returned no data for stack: ${stack_name}"
        return 0
    fi

    # Parse resource types and extract IDs using jq
    # AWS::Bedrock::Agent
    local agent_ids_raw
    agent_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::Agent")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r aid; do
        [ -n "$aid" ] && AGENT_IDS+=("$aid")
    done <<< "$agent_ids_raw"

    # AWS::Bedrock::KnowledgeBase
    local kb_ids_raw
    kb_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::KnowledgeBase")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r kid; do
        [ -n "$kid" ] && KB_IDS+=("$kid")
    done <<< "$kb_ids_raw"

    # AWS::Bedrock::Guardrail
    local gr_ids_raw
    gr_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::Guardrail")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r gid; do
        [ -n "$gid" ] && GUARDRAIL_IDS+=("$gid")
    done <<< "$gr_ids_raw"

    # AWS::Bedrock::Flow
    local flow_ids_raw
    flow_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::Flow")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r fid; do
        [ -n "$fid" ] && FLOW_IDS+=("$fid")
    done <<< "$flow_ids_raw"

    # AWS::IAM::Role
    local role_names_raw
    role_names_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::IAM::Role")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r rname; do
        [ -n "$rname" ] && ROLE_NAMES+=("$rname")
    done <<< "$role_names_raw"

    # AWS::SageMaker::Endpoint
    local ep_names_raw
    ep_names_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::SageMaker::Endpoint")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r epname; do
        [ -n "$epname" ] && ENDPOINT_NAMES+=("$epname")
    done <<< "$ep_names_raw"

    # AWS::SageMaker::EndpointConfig
    local ep_cfg_names_raw
    ep_cfg_names_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::SageMaker::EndpointConfig")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r cfgname; do
        [ -n "$cfgname" ] && ENDPOINT_CONFIG_NAMES+=("$cfgname")
    done <<< "$ep_cfg_names_raw"

    # AWS::CloudTrail::Trail
    local trail_arns_raw
    trail_arns_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::CloudTrail::Trail")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r tarn; do
        [ -n "$tarn" ] && TRAIL_ARNS+=("$tarn")
    done <<< "$trail_arns_raw"

    # AWS::Cognito::UserPool
    local pool_ids_raw
    pool_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Cognito::UserPool")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r pid; do
        [ -n "$pid" ] && USER_POOL_IDS+=("$pid")
    done <<< "$pool_ids_raw"

    # AWS::Bedrock::CustomModel
    local cm_ids_raw
    cm_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::CustomModel")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r cmid; do
        [ -n "$cmid" ] && CUSTOM_MODEL_IDS+=("$cmid")
    done <<< "$cm_ids_raw"

    # AWS::Lambda::Function — action-group backing Lambdas declared in the stack
    local lambda_names_raw
    lambda_names_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Lambda::Function")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r lname; do
        [ -n "$lname" ] && LAMBDA_NAMES+=("$lname")
    done <<< "$lambda_names_raw"

    # AWS::BedrockAgentCore::Runtime (AgentCore Runtime)
    local ac_rt_ids_raw
    ac_rt_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::BedrockAgentCore::Runtime")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r rt_id; do
        [ -n "$rt_id" ] && AGENTCORE_RUNTIME_IDS+=("$rt_id")
    done <<< "$ac_rt_ids_raw"

    # AWS::BedrockAgentCore::Gateway (AgentCore Gateway)
    local ac_gw_ids_raw
    ac_gw_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::BedrockAgentCore::Gateway")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r gw_id; do
        [ -n "$gw_id" ] && AGENTCORE_GATEWAY_IDS+=("$gw_id")
    done <<< "$ac_gw_ids_raw"

    # AWS::BedrockAgentCore::WorkloadIdentity (AgentCore Identity)
    local ac_wid_ids_raw
    ac_wid_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::BedrockAgentCore::WorkloadIdentity")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r wid; do
        [ -n "$wid" ] && AGENTCORE_IDENTITY_IDS+=("$wid")
    done <<< "$ac_wid_ids_raw"

    # AWS::BedrockAgentCore::Memory (AgentCore Memory)
    local ac_mem_ids_raw
    ac_mem_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::BedrockAgentCore::Memory")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r mem_id; do
        [ -n "$mem_id" ] && AGENTCORE_MEMORY_IDS+=("$mem_id")
    done <<< "$ac_mem_ids_raw"

    # AWS::Bedrock::Prompt (Bedrock Prompt Management)
    local prompt_ids_raw
    prompt_ids_raw=$(jq -r '
        .StackResourceSummaries[]?
        | select(.ResourceType == "AWS::Bedrock::Prompt")
        | .PhysicalResourceId // empty
    ' "$resources_file" 2>/dev/null || true)
    while IFS= read -r p_id; do
        [ -n "$p_id" ] && PROMPT_IDS+=("$p_id")
    done <<< "$prompt_ids_raw"

    fetch_resource_details
}

# ---------------------------------------------------------------------------
# Shared detail-fetch routine — called after resource arrays are populated.
# Fetches detailed config for each discovered resource and runs supplementary
# account-level discovery (CloudTrail, Cognito, AgentCore families, Prompts).
# ---------------------------------------------------------------------------
fetch_resource_details() {
    # For each discovered agent, run get-agent to extract model_id and role_arn
    local i=0
    while [ "$i" -lt "${#AGENT_IDS[@]}" ]; do
        local aid="${AGENT_IDS[$i]}"
        local agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent-${aid}.json"
        fetch_or_cache "$agent_file" \
            aws bedrock-agent get-agent --agent-id "$aid" \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$agent_file"; then
            local model_id role_arn role_name
            model_id=$(jq -r '.agent.foundationModel // empty' "$agent_file" 2>/dev/null || true)
            role_arn=$(jq -r '.agent.agentResourceRoleArn // empty' "$agent_file" 2>/dev/null || true)

            # Resolve foundation model through inference-profile chain (R3.1, R3.3)
            if [ -n "$model_id" ]; then
                local resolved
                set +e
                resolved=$(resolve_component_model "$model_id" "$model_id")
                local rc=$?
                set -e
                if [ "$rc" -eq 0 ] && [ -n "$resolved" ]; then
                    local resolved_model
                    resolved_model=$(printf '%s' "$resolved" | cut -d'|' -f1)
                    [ -n "$resolved_model" ] && MODELS+=("$resolved_model")
                    BEDROCK_AGENT_MODELS+=("${aid}|${resolved}")
                else
                    MODELS_NEEDING_RESOLUTION+=("$aid")
                fi
            fi

            if [ -n "$role_arn" ]; then
                role_name="${role_arn##*/}"
                [ -n "$role_name" ] && ROLE_NAMES+=("$role_name")
            fi
        fi
        i=$((i + 1))
    done

    # For each agent, also pull action-groups to pick up Lambda functions
    # wired outside the primary resource source.
    i=0
    while [ "$i" -lt "${#AGENT_IDS[@]}" ]; do
        local aid2="${AGENT_IDS[$i]}"
        local versions_cfn
        versions_cfn=$(resolve_agent_versions "$aid2" "$RAW_DATA_DIR")
        log_info "Agent ${aid2} versions to query: $(echo "$versions_cfn" | tr '\n' ' ')"

        while IFS= read -r ver_cfn; do
            [ -z "$ver_cfn" ] && continue
            local ag_file="$RAW_DATA_DIR/bedrock-agent-list-agent-action-groups-${aid2}-${ver_cfn}.json"
            fetch_or_cache "$ag_file" \
                aws bedrock-agent list-agent-action-groups \
                    --agent-id "$aid2" --agent-version "$ver_cfn" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json
            extract_lambda_names_from_action_groups "$ag_file"
        done <<< "$versions_cfn"
        i=$((i + 1))
    done

    # Supplementary account-level discovery: CloudTrail trails and Cognito
    # user pools are frequently managed outside the solution stack.
    local ct_file="$RAW_DATA_DIR/cloudtrail-describe-trails.json"
    fetch_or_cache "$ct_file" \
        aws cloudtrail describe-trails \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ct_file"; then
        local trail_arns_supp
        trail_arns_supp=$(jq -r '.trailList[]?.TrailARN // empty' "$ct_file" 2>/dev/null || true)
        while IFS= read -r tarn2; do
            [ -n "$tarn2" ] && TRAIL_ARNS+=("$tarn2")
        done <<< "$trail_arns_supp"
    fi

    local cognito_file="$RAW_DATA_DIR/cognito-list-user-pools.json"
    fetch_or_cache "$cognito_file" \
        aws cognito-idp list-user-pools --max-results 10 \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$cognito_file"; then
        local pool_ids_supp
        pool_ids_supp=$(jq -r '.UserPools[]?.Id // empty' "$cognito_file" 2>/dev/null || true)
        while IFS= read -r pid2; do
            [ -n "$pid2" ] && USER_POOL_IDS+=("$pid2")
        done <<< "$pool_ids_supp"
    fi

    # --- AgentCore families (new CLI; use fetch_family_with_cli_check) ---
    # Only enumerate account-wide AgentCore lists when the corresponding
    # resource type was already discovered, to avoid pulling unrelated resources.
    local has_agentcore_runtime=0 has_agentcore_gateway=0
    local has_agentcore_identity=0 has_agentcore_memory=0
    [ "${#AGENTCORE_RUNTIME_IDS[@]}" -gt 0 ] && has_agentcore_runtime=1
    [ "${#AGENTCORE_GATEWAY_IDS[@]}" -gt 0 ] && has_agentcore_gateway=1
    [ "${#AGENTCORE_IDENTITY_IDS[@]}" -gt 0 ] && has_agentcore_identity=1
    [ "${#AGENTCORE_MEMORY_IDS[@]}" -gt 0 ] && has_agentcore_memory=1

    # AgentCore Runtimes
    if [ "$has_agentcore_runtime" -eq 1 ]; then
        local ac_rt_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-agent-runtimes.json"
        fetch_family_with_cli_check "$ac_rt_file" "AgentCore Runtimes" \
            aws bedrock-agentcore-control list-agent-runtimes \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$ac_rt_file"; then
            local ac_rt_ids_supp
            ac_rt_ids_supp=$(jq -r '.agentRuntimes[]?.agentRuntimeId // empty' "$ac_rt_file" 2>/dev/null || true)
            while IFS= read -r rt_id; do
                [ -n "$rt_id" ] && AGENTCORE_RUNTIME_IDS+=("$rt_id")
            done <<< "$ac_rt_ids_supp"
        fi
    fi

    # AgentCore Gateways
    if [ "$has_agentcore_gateway" -eq 1 ]; then
        local ac_gw_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-gateways.json"
        fetch_family_with_cli_check "$ac_gw_file" "AgentCore Gateways" \
            aws bedrock-agentcore-control list-gateways \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$ac_gw_file"; then
            local ac_gw_ids_supp
            ac_gw_ids_supp=$(jq -r '.items[]?.gatewayId // empty' "$ac_gw_file" 2>/dev/null || true)
            while IFS= read -r gw_id; do
                [ -n "$gw_id" ] && AGENTCORE_GATEWAY_IDS+=("$gw_id")
            done <<< "$ac_gw_ids_supp"
        fi
    fi

    # AgentCore Workload Identities
    if [ "$has_agentcore_identity" -eq 1 ]; then
        local ac_id_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-workload-identities.json"
        fetch_family_with_cli_check "$ac_id_file" "AgentCore Workload Identities" \
            aws bedrock-agentcore-control list-workload-identities \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$ac_id_file"; then
            local ac_id_ids_supp
            ac_id_ids_supp=$(jq -r '.workloadIdentities[]?.name // empty' "$ac_id_file" 2>/dev/null || true)
            while IFS= read -r wid; do
                [ -n "$wid" ] && AGENTCORE_IDENTITY_IDS+=("$wid")
            done <<< "$ac_id_ids_supp"
        fi
    fi

    # AgentCore Memory stores
    if [ "$has_agentcore_memory" -eq 1 ]; then
        local ac_mem_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-memories.json"
        fetch_family_with_cli_check "$ac_mem_file" "AgentCore Memory" \
            aws bedrock-agentcore-control list-memories \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$ac_mem_file"; then
            local ac_mem_ids_supp
            ac_mem_ids_supp=$(jq -r '.memories[]?.memoryId // empty' "$ac_mem_file" 2>/dev/null || true)
            while IFS= read -r mem_id; do
                [ -n "$mem_id" ] && AGENTCORE_MEMORY_IDS+=("$mem_id")
            done <<< "$ac_mem_ids_supp"
        fi
    fi

    # Bedrock Prompt Management (established CLI; use regular fetch_or_cache)
    local prompts_file="$RAW_DATA_DIR/bedrock-agent-list-prompts.json"
    fetch_or_cache "$prompts_file" \
        aws bedrock-agent list-prompts \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$prompts_file"; then
        local prompt_ids_supp
        prompt_ids_supp=$(jq -r '.promptSummaries[]?.id // empty' "$prompts_file" 2>/dev/null || true)
        while IFS= read -r p_id; do
            [ -n "$p_id" ] && PROMPT_IDS+=("$p_id")
        done <<< "$prompt_ids_supp"
    fi

    # Get ACCOUNT_ID from sts if not already set
    if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "N/A" ]; then
        local sts_file="$RAW_DATA_DIR/sts-get-caller-identity.json"
        if check_result "$sts_file"; then
            ACCOUNT_ID=$(jq -r '.Account // empty' "$sts_file" 2>/dev/null || echo "")
        fi
    fi
}

# ---------------------------------------------------------------------------
# Discovery path B2: Terraform state
# ---------------------------------------------------------------------------
discover_terraform_state() {
    progress "Discovering resources from Terraform state in: ${TF_STATE_DIR}..."

    INPUT_TYPE="tf-state"

    # Validate terraform CLI is available
    if ! command -v terraform >/dev/null 2>&1; then
        echo "ERROR: 'terraform' CLI not found in PATH. Install from https://developer.hashicorp.com/terraform/install" >&2
        exit 1
    fi

    # Validate directory exists
    if [ ! -d "$TF_STATE_DIR" ]; then
        echo "ERROR: --tf-state-dir path does not exist: ${TF_STATE_DIR}" >&2
        exit 1
    fi

    # Pull state into raw data dir
    local state_file="$RAW_DATA_DIR/terraform-state.json"
    progress "Running terraform state pull..."
    local tf_output=""
    local rc=0
    tf_output=$(cd "$TF_STATE_DIR" && terraform state pull 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        # Fallback: try reading terraform.tfstate directly (local backend)
        local local_state="${TF_STATE_DIR}/terraform.tfstate"
        if [ -f "$local_state" ] && jq empty "$local_state" >/dev/null 2>&1; then
            log_warn "terraform state pull failed; falling back to local state file: ${local_state}"
            tf_output=$(cat "$local_state")
        else
            echo "ERROR: terraform state pull failed (exit ${rc}): ${tf_output}" >&2
            exit 1
        fi
    fi

    if [ -z "$tf_output" ] || ! echo "$tf_output" | jq empty >/dev/null 2>&1; then
        echo "ERROR: terraform state pull returned invalid JSON" >&2
        exit 1
    fi

    echo "$tf_output" > "$state_file"
    log_info "Terraform state saved to: ${state_file}"

    # Extract account ID from aws_caller_identity data source if present
    local tf_account_id
    tf_account_id=$(jq -r '
        [ .resources[]?
          | select(.type == "aws_caller_identity")
          | .instances[0]?.attributes?.account_id // empty
        ] | first // empty
    ' "$state_file" 2>/dev/null || true)
    if [ -n "$tf_account_id" ]; then
        ACCOUNT_ID="$tf_account_id"
        log_info "Account ID from Terraform state: ${ACCOUNT_ID}"
    fi

    # Extract region from aws_region data source if present
    local tf_region
    tf_region=$(jq -r '
        [ .resources[]?
          | select(.type == "aws_region")
          | .instances[0]?.attributes?.name // empty
        ] | first // empty
    ' "$state_file" 2>/dev/null || true)
    if [ -n "$tf_region" ] && [ -z "$REGION" ]; then
        REGION="$tf_region"
        log_info "Region from Terraform state: ${REGION}"
    fi

    # --- Parse managed resources by Terraform type ---
    # Terraform resource types use underscores; we match against known GenAI types.

    # awscc_bedrock_agent / aws_bedrock_agent_agent → agent_ids
    local agent_ids_raw
    agent_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_agent" or .type == "aws_bedrock_agent_agent")
        | .instances[]?
        | (.attributes.agent_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r aid; do
        [ -n "$aid" ] && AGENT_IDS+=("$aid")
    done <<< "$agent_ids_raw"

    # awscc_bedrock_knowledge_base / aws_bedrock_agent_knowledge_base → kb_ids
    local kb_ids_raw
    kb_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_knowledge_base" or .type == "aws_bedrock_agent_knowledge_base")
        | .instances[]?
        | (.attributes.knowledge_base_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r kid; do
        [ -n "$kid" ] && KB_IDS+=("$kid")
    done <<< "$kb_ids_raw"

    # awscc_bedrock_guardrail / aws_bedrock_guardrail → guardrail_ids
    local gr_ids_raw
    gr_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_guardrail" or .type == "aws_bedrock_guardrail")
        | .instances[]?
        | (.attributes.guardrail_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r gid; do
        [ -n "$gid" ] && GUARDRAIL_IDS+=("$gid")
    done <<< "$gr_ids_raw"

    # awscc_bedrock_flow / aws_bedrock_agent_flow → flow_ids
    local flow_ids_raw
    flow_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_flow" or .type == "aws_bedrock_agent_flow")
        | .instances[]?
        | (.attributes.flow_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r fid; do
        [ -n "$fid" ] && FLOW_IDS+=("$fid")
    done <<< "$flow_ids_raw"

    # aws_iam_role → role_names
    local role_names_raw
    role_names_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_iam_role")
        | .instances[]?
        | (.attributes.name // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r rname; do
        [ -n "$rname" ] && ROLE_NAMES+=("$rname")
    done <<< "$role_names_raw"

    # aws_sagemaker_endpoint → endpoint_names
    local ep_names_raw
    ep_names_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_sagemaker_endpoint")
        | .instances[]?
        | (.attributes.name // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r epname; do
        [ -n "$epname" ] && ENDPOINT_NAMES+=("$epname")
    done <<< "$ep_names_raw"

    # aws_sagemaker_endpoint_configuration → endpoint_config_names
    local ep_cfg_names_raw
    ep_cfg_names_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_sagemaker_endpoint_configuration")
        | .instances[]?
        | (.attributes.name // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r cfgname; do
        [ -n "$cfgname" ] && ENDPOINT_CONFIG_NAMES+=("$cfgname")
    done <<< "$ep_cfg_names_raw"

    # aws_cloudtrail → trail_arns
    local trail_arns_raw
    trail_arns_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_cloudtrail")
        | .instances[]?
        | (.attributes.arn // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r tarn; do
        [ -n "$tarn" ] && TRAIL_ARNS+=("$tarn")
    done <<< "$trail_arns_raw"

    # aws_cognito_user_pool → user_pool_ids
    local pool_ids_raw
    pool_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_cognito_user_pool")
        | .instances[]?
        | (.attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r pid; do
        [ -n "$pid" ] && USER_POOL_IDS+=("$pid")
    done <<< "$pool_ids_raw"

    # aws_bedrock_custom_model → custom_model_ids
    local cm_ids_raw
    cm_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_bedrock_custom_model")
        | .instances[]?
        | (.attributes.model_arn // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r cmid; do
        [ -n "$cmid" ] && CUSTOM_MODEL_IDS+=("$cmid")
    done <<< "$cm_ids_raw"

    # aws_lambda_function → lambda_names
    local lambda_names_raw
    lambda_names_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_lambda_function")
        | .instances[]?
        | (.attributes.function_name // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r lname; do
        [ -n "$lname" ] && LAMBDA_NAMES+=("$lname")
    done <<< "$lambda_names_raw"

    # awscc_bedrock_agent → extract foundation_model
    local models_raw
    models_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_agent" or .type == "aws_bedrock_agent_agent")
        | .instances[]?
        | (.attributes.foundation_model // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r mid; do
        [ -n "$mid" ] && MODELS+=("$mid")
    done <<< "$models_raw"

    # Bedrock Prompt (awscc_bedrock_prompt) → prompt_ids
    local prompt_ids_raw
    prompt_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "awscc_bedrock_prompt" or .type == "aws_bedrock_prompt")
        | .instances[]?
        | (.attributes.prompt_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r p_id; do
        [ -n "$p_id" ] && PROMPT_IDS+=("$p_id")
    done <<< "$prompt_ids_raw"

    # aws_bedrockagentcore_agent_runtime → agentcore_runtime_ids
    local ac_rt_ids_raw
    ac_rt_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_bedrockagentcore_agent_runtime")
        | .instances[]?
        | (.attributes.agent_runtime_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r rt_id; do
        [ -n "$rt_id" ] && AGENTCORE_RUNTIME_IDS+=("$rt_id")
    done <<< "$ac_rt_ids_raw"

    # aws_bedrockagentcore_gateway → agentcore_gateway_ids
    local ac_gw_ids_raw
    ac_gw_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_bedrockagentcore_gateway")
        | .instances[]?
        | (.attributes.gateway_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r gw_id; do
        [ -n "$gw_id" ] && AGENTCORE_GATEWAY_IDS+=("$gw_id")
    done <<< "$ac_gw_ids_raw"

    # aws_bedrockagentcore_workload_identity → agentcore_identity_ids
    local ac_wid_ids_raw
    ac_wid_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_bedrockagentcore_workload_identity")
        | .instances[]?
        | (.attributes.name // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r wid; do
        [ -n "$wid" ] && AGENTCORE_IDENTITY_IDS+=("$wid")
    done <<< "$ac_wid_ids_raw"

    # aws_bedrockagentcore_memory → agentcore_memory_ids
    local ac_mem_ids_raw
    ac_mem_ids_raw=$(jq -r '
        .resources[]?
        | select(.mode == "managed")
        | select(.type == "aws_bedrockagentcore_memory")
        | .instances[]?
        | (.attributes.memory_id // .attributes.id // empty)
    ' "$state_file" 2>/dev/null || true)
    while IFS= read -r mem_id; do
        [ -n "$mem_id" ] && AGENTCORE_MEMORY_IDS+=("$mem_id")
    done <<< "$ac_mem_ids_raw"

    # --- Supplementary live API calls (same as CFN path) ---

    # For each discovered agent, fetch get-agent to extract model/role
    local i=0
    while [ "$i" -lt "${#AGENT_IDS[@]}" ]; do
        local aid="${AGENT_IDS[$i]}"
        local agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent-${aid}.json"
        fetch_or_cache "$agent_file" \
            aws bedrock-agent get-agent --agent-id "$aid" \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$agent_file"; then
            local model_id role_arn role_name
            model_id=$(jq -r '.agent.foundationModel // empty' "$agent_file" 2>/dev/null || true)
            role_arn=$(jq -r '.agent.agentResourceRoleArn // empty' "$agent_file" 2>/dev/null || true)

            # Resolve foundation model through inference-profile chain (R3.1, R3.3)
            if [ -n "$model_id" ]; then
                local resolved
                set +e
                resolved=$(resolve_component_model "$model_id" "$model_id")
                local rc=$?
                set -e
                if [ "$rc" -eq 0 ] && [ -n "$resolved" ]; then
                    local resolved_model
                    resolved_model=$(printf '%s' "$resolved" | cut -d'|' -f1)
                    [ -n "$resolved_model" ] && MODELS+=("$resolved_model")
                    BEDROCK_AGENT_MODELS+=("${aid}|${resolved}")
                else
                    MODELS_NEEDING_RESOLUTION+=("$aid")
                fi
            fi

            if [ -n "$role_arn" ]; then
                role_name="${role_arn##*/}"
                [ -n "$role_name" ] && ROLE_NAMES+=("$role_name")
            fi
        fi
        i=$((i + 1))
    done

    # For each agent, pull action-groups (mirrors CFN path)
    i=0
    while [ "$i" -lt "${#AGENT_IDS[@]}" ]; do
        local aid2="${AGENT_IDS[$i]}"
        local versions_tf
        versions_tf=$(resolve_agent_versions "$aid2" "$RAW_DATA_DIR")
        log_info "Agent ${aid2} versions to query: $(echo "$versions_tf" | tr '\n' ' ')"

        while IFS= read -r ver_tf; do
            [ -z "$ver_tf" ] && continue
            local ag_file="$RAW_DATA_DIR/bedrock-agent-list-agent-action-groups-${aid2}-${ver_tf}.json"
            fetch_or_cache "$ag_file" \
                aws bedrock-agent list-agent-action-groups \
                    --agent-id "$aid2" --agent-version "$ver_tf" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json
            extract_lambda_names_from_action_groups "$ag_file"
        done <<< "$versions_tf"
        i=$((i + 1))
    done

    # Supplementary: CloudTrail, Cognito (account-level)
    local ct_file="$RAW_DATA_DIR/cloudtrail-describe-trails.json"
    fetch_or_cache "$ct_file" \
        aws cloudtrail describe-trails \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ct_file"; then
        local trail_arns_supp
        trail_arns_supp=$(jq -r '.trailList[]?.TrailARN // empty' "$ct_file" 2>/dev/null || true)
        while IFS= read -r tarn2; do
            [ -n "$tarn2" ] && TRAIL_ARNS+=("$tarn2")
        done <<< "$trail_arns_supp"
    fi

    local cognito_file="$RAW_DATA_DIR/cognito-list-user-pools.json"
    fetch_or_cache "$cognito_file" \
        aws cognito-idp list-user-pools --max-results 10 \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$cognito_file"; then
        local pool_ids_supp
        pool_ids_supp=$(jq -r '.UserPools[]?.Id // empty' "$cognito_file" 2>/dev/null || true)
        while IFS= read -r pid2; do
            [ -n "$pid2" ] && USER_POOL_IDS+=("$pid2")
        done <<< "$pool_ids_supp"
    fi

    # Get ACCOUNT_ID from sts if not already set
    if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "N/A" ]; then
        local sts_file="$RAW_DATA_DIR/sts-get-caller-identity.json"
        if check_result "$sts_file"; then
            ACCOUNT_ID=$(jq -r '.Account // empty' "$sts_file" 2>/dev/null || echo "")
        fi
    fi
}

# ---------------------------------------------------------------------------
# Discovery path C: AppRegistry
# ---------------------------------------------------------------------------
discover_app_registry() {
    progress "Discovering resources from AppRegistry..."

    INPUT_TYPE="app-arn"

    # Extract app_id from ARN (last path component)
    local app_id
    app_id="${APP_ARN##*/}"

    log_info "AppRegistry application ID: ${app_id}"

    # get-application
    local app_file="$RAW_DATA_DIR/appregistry-get-application.json"
    fetch_or_cache "$app_file" \
        aws servicecatalog-appregistry get-application \
            --application "$app_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    # list-associated-resources
    local assoc_file="$RAW_DATA_DIR/appregistry-list-associated-resources.json"
    fetch_or_cache "$assoc_file" \
        aws servicecatalog-appregistry list-associated-resources \
            --application "$app_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$assoc_file"; then
        # For each associated CloudFormation stack, delegate to CFN discovery
        local stack_names_raw
        stack_names_raw=$(jq -r '
            .resources[]?
            | select(.resourceType == "CFN_STACK")
            | .name // empty
        ' "$assoc_file" 2>/dev/null || true)

        while IFS= read -r sname; do
            if [ -n "$sname" ]; then
                log_info "Delegating to CFN discovery for stack: ${sname}"
                discover_cfn_stack "$sname"
            fi
        done <<< "$stack_names_raw"
    fi
}


# ---------------------------------------------------------------------------
# Discovery path D: AWS Resource Group
# ---------------------------------------------------------------------------
discover_resource_group() {
    progress "Discovering resources from Resource Group..."

    INPUT_TYPE="resource-group"

    # Accept either full ARN or group name.
    local group_id="$RESOURCE_GROUP"
    if echo "$RESOURCE_GROUP" | grep -q '^arn:'; then
        # Extract account from ARN field 5
        ACCOUNT_ID=$(echo "$RESOURCE_GROUP" | cut -d: -f5)
        # Validate region matches (ARN field 4)
        local group_region
        group_region=$(echo "$RESOURCE_GROUP" | cut -d: -f4)
        if [ -n "$group_region" ] && [ "$group_region" != "$REGION" ]; then
            log_warn "Resource Group region (${group_region}) differs from --region (${REGION}); using group region"
            REGION="$group_region"
        fi
        # Extract group name (last path segment)
        group_id="${RESOURCE_GROUP##*/}"
    fi

    log_info "Resource Group: ${group_id}"

    # get-group (metadata/evidence)
    local group_file="$RAW_DATA_DIR/resource-groups-get-group.json"
    fetch_or_cache "$group_file" \
        aws resource-groups get-group \
            --group "$group_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    # list-group-resources (member resources)
    local members_file="$RAW_DATA_DIR/resource-groups-list-group-resources.json"
    fetch_or_cache "$members_file" \
        aws resource-groups list-group-resources \
            --group "$group_id" --no-paginate \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if ! check_result "$members_file"; then
        log_warn "list-group-resources returned no data for group: ${group_id}"
        return 0
    fi

    # --- Classify resources by type ---
    # Resource Group returns .Resources[].Identifier.{ResourceArn, ResourceType}
    # We extract the resource ID from the ARN for each known type.

    # Helper: extract last segment from ARN (after final / or :)
    # Works for: arn:aws:bedrock:...:agent/ID, arn:aws:lambda:...:function:name,
    #            arn:aws:iam::acct:role/name, arn:aws:cognito-idp:...:userpool/id
    arn_to_id() { echo "$1" | grep -oE '[^/:]+$'; }

    # AWS::CloudFormation::Stack — delegate to discover_cfn_stack for deeper extraction.
    # CFN stack ARN format: arn:aws:cloudformation:<region>:<acct>:stack/<name>/<uuid>
    # Pass the full ARN (CloudFormation --stack-name accepts ARNs).
    local stack_arns_raw
    stack_arns_raw=$(jq -r '
        .Resources[]? | select(.Identifier.ResourceType == "AWS::CloudFormation::Stack")
        | .Identifier.ResourceArn // empty
    ' "$members_file" 2>/dev/null || true)
    while IFS= read -r stack_arn; do
        if [ -n "$stack_arn" ]; then
            log_info "Delegating to CFN discovery for stack: ${stack_arn}"
            discover_cfn_stack "$stack_arn"
        fi
    done <<< "$stack_arns_raw"

    # AWS::Bedrock::Agent
    local arns_raw
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::Agent") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && AGENT_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::Bedrock::AgentAlias — tag-based groups surface aliases, not agents.
    # ARN format: arn:aws:bedrock:<region>:<acct>:agent-alias/<AGENT_ID>/<ALIAS_ID>
    # Extract the agent ID (second-to-last path segment).
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::AgentAlias") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        if [ -n "$arn" ]; then
            local agent_id_from_alias
            agent_id_from_alias="${arn##*agent-alias/}"
            agent_id_from_alias="${agent_id_from_alias%%/*}"
            [ -n "$agent_id_from_alias" ] && AGENT_IDS+=("$agent_id_from_alias")
        fi
    done <<< "$arns_raw"

    # AWS::Bedrock::KnowledgeBase
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::KnowledgeBase") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && KB_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::Bedrock::Guardrail (store full ARN — CFN path also stores ARN as PhysicalResourceId;
    # downstream get-guardrail accepts both ARN and short ID)
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::Guardrail") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && GUARDRAIL_IDS+=("$arn")
    done <<< "$arns_raw"

    # AWS::Bedrock::Flow
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::Flow") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && FLOW_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::Bedrock::CustomModel
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::CustomModel") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && CUSTOM_MODEL_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::Bedrock::Prompt
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Bedrock::Prompt") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && PROMPT_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::BedrockAgentCore::Runtime
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::BedrockAgentCore::Runtime") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && AGENTCORE_RUNTIME_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::BedrockAgentCore::Gateway
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::BedrockAgentCore::Gateway") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && AGENTCORE_GATEWAY_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::BedrockAgentCore::WorkloadIdentity
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::BedrockAgentCore::WorkloadIdentity") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && AGENTCORE_IDENTITY_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::BedrockAgentCore::Memory
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::BedrockAgentCore::Memory") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && AGENTCORE_MEMORY_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::Lambda::Function
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Lambda::Function") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && LAMBDA_NAMES+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::IAM::Role
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::IAM::Role") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && ROLE_NAMES+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::SageMaker::Endpoint
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::SageMaker::Endpoint") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && ENDPOINT_NAMES+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::SageMaker::EndpointConfig
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::SageMaker::EndpointConfig") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && ENDPOINT_CONFIG_NAMES+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # AWS::CloudTrail::Trail (store full ARN)
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::CloudTrail::Trail") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && TRAIL_ARNS+=("$arn")
    done <<< "$arns_raw"

    # AWS::Cognito::UserPool
    arns_raw=$(jq -r '.Resources[]? | select(.Identifier.ResourceType == "AWS::Cognito::UserPool") | .Identifier.ResourceArn // empty' "$members_file" 2>/dev/null || true)
    while IFS= read -r arn; do
        [ -n "$arn" ] && USER_POOL_IDS+=("$(arn_to_id "$arn")")
    done <<< "$arns_raw"

    # Run shared detail-fetch (get-agent, action-groups, CloudTrail, Cognito,
    # AgentCore families, Prompts, STS fallback)
    fetch_resource_details
}


# ---------------------------------------------------------------------------
# WA Lens pull (DEPRECATED — kept as a no-op for backwards compatibility)
# ---------------------------------------------------------------------------
# Check definitions are sourced exclusively from the bundled references under
# ${SKILL_ROOT}/references/ (check-registry.json + framework YAMLs). The
# Well-Architected Tool's GenAI Lens is not generally available as an
# AWS_OFFICIAL lens, so the runtime API pull always fell through to the
# bundled fallback. The function is retained as an empty stub so any external
# caller does not break; new code paths should not invoke it.
# shellcheck disable=SC2329 # retained no-op for backwards-compat external callers
pull_wa_lens() {
    return 0
}

# ---------------------------------------------------------------------------
# Inference-profile lookup helper (R3.2, R3.9)
# ---------------------------------------------------------------------------
# resolve_inference_profile <id_or_arn>
#   Echoes the comma-joined underlying modelArn(s) for the given inference
#   profile id or ARN, consulting the pre-populated INFERENCE_PROFILES[] first
#   and falling back to an on-demand cached `get-inference-profile` call.
#   Echoes "" (empty) and returns 0 if the id_or_arn is not a known profile.
resolve_inference_profile() {
    local id_or_arn="$1"
    [ -z "$id_or_arn" ] && return 0

    # Search the pre-populated INFERENCE_PROFILES[] rows (id|arn|type|modelArns)
    local i=0
    while [ "$i" -lt "${#INFERENCE_PROFILES[@]}" ]; do
        local row="${INFERENCE_PROFILES[$i]}"
        local row_id row_arn row_models
        row_id=$(echo "$row" | cut -d'|' -f1)
        row_arn=$(echo "$row" | cut -d'|' -f2)
        row_models=$(echo "$row" | cut -d'|' -f4)
        if [ "$id_or_arn" = "$row_id" ] || [ "$id_or_arn" = "$row_arn" ]; then
            echo "$row_models"
            return 0
        fi
        i=$((i + 1))
    done

    # Not found in the list — fall back to an on-demand get-inference-profile.
    # Cache the response so repeated lookups for the same profile are free.
    local safe_id
    safe_id="${id_or_arn//[\/:]/_}"
    local ip_detail_file="$RAW_DATA_DIR/bedrock-get-inference-profile-${safe_id}.json"
    fetch_or_cache "$ip_detail_file" \
        aws bedrock get-inference-profile \
            --inference-profile-identifier "$id_or_arn" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

    if check_result "$ip_detail_file"; then
        local models
        models=$(jq -r '[.models[]?.modelArn] | join(",")' "$ip_detail_file" 2>/dev/null)
        if [ -n "$models" ]; then
            # Cache this profile into INFERENCE_PROFILES[] for future lookups
            local pid parn ptype
            pid=$(jq -r '.inferenceProfileId // empty' "$ip_detail_file" 2>/dev/null)
            parn=$(jq -r '.inferenceProfileArn // empty' "$ip_detail_file" 2>/dev/null)
            ptype=$(jq -r '.type // empty' "$ip_detail_file" 2>/dev/null)
            INFERENCE_PROFILES+=("${pid}|${parn}|${ptype}|${models}")
            echo "$models"
            return 0
        fi
    fi

    # Not an inference profile — return empty
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# Inference-profile field extractor (R3.9)
# ---------------------------------------------------------------------------
# ip_field <id_or_arn> <field>
#   Returns the requested field (id, arn, type) from INFERENCE_PROFILES[] for
#   the given id_or_arn. Used by resolve_component_model to record provenance.
ip_field() {
    local id_or_arn="$1" field="$2"
    local i=0
    while [ "$i" -lt "${#INFERENCE_PROFILES[@]}" ]; do
        local row="${INFERENCE_PROFILES[$i]}"
        local row_id row_arn row_type
        row_id=$(echo "$row" | cut -d'|' -f1)
        row_arn=$(echo "$row" | cut -d'|' -f2)
        row_type=$(echo "$row" | cut -d'|' -f3)
        if [ "$id_or_arn" = "$row_id" ] || [ "$id_or_arn" = "$row_arn" ]; then
            case "$field" in
                id)   echo "$row_id" ;;
                arn)  echo "$row_arn" ;;
                type) echo "$row_type" ;;
            esac
            return 0
        fi
        i=$((i + 1))
    done
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# Component model resolution priority chain (R3.1, R3.3, R3.4)
# ---------------------------------------------------------------------------
# resolve_component_model <cfg_model> <direct_cli_field_value>
# Echoes "model|source[|profile_id|profile_arn|underlying_arns]" and returns 0
# when it resolves via an inference profile or a direct CLI field; returns 1
# (echoing nothing) when neither source resolves.
resolve_component_model() {
    local cfg="$1" direct="$2" arns=""

    # (1) Inference profile: cfg matches a known profile id/arn → deref.
    if [ -n "$cfg" ]; then
        arns=$(resolve_inference_profile "$cfg")
        if [ -n "$arns" ]; then
            local pid parn
            pid=$(ip_field "$cfg" id)
            parn=$(ip_field "$cfg" arn)
            printf '%s|inference_profile|%s|%s|%s\n' "$arns" "$pid" "$parn" "$arns"
            return 0
        fi
    fi

    # (2) Direct CLI model field.
    if [ -n "$direct" ] && [ "$direct" != "null" ]; then
        printf '%s|cli_field\n' "$direct"
        return 0
    fi

    # Neither source resolved — the caller flags this component for the
    # orchestrator (code/user/undetermined). No model entry, no source written.
    return 1
}

# ---------------------------------------------------------------------------
# Array deduplication helper (bash 3.2 compatible)
# ---------------------------------------------------------------------------
dedup_array() {
    # Reads from the named array variable, deduplicates, writes back.
    # Usage: dedup_array ARRAY_NAME
    # Since bash 3.2 doesn't support namerefs, we use eval carefully.
    local arr_name="$1"
    local seen=""
    local result=()
    local val

    # Use eval to get array contents — safe because arr_name is controlled.
    # shellcheck disable=SC2154 # arr_copy is assigned dynamically via eval
    local arr_copy=()
    eval "arr_copy=(\"\${${arr_name}[@]+\"\${${arr_name}[@]}\"}\") "

    local i=0
    while [ "$i" -lt "${#arr_copy[@]}" ]; do
        val="${arr_copy[$i]}"
        if [ -n "$val" ] && ! echo "$seen" | grep -qF "|${val}|"; then
            result+=("$val")
            seen="${seen}|${val}|"
        fi
        i=$((i + 1))
    done

    eval "${arr_name}=(\"\${result[@]+\"\${result[@]}\"}\") "
}

# ---------------------------------------------------------------------------
# Convert bash array to JSON array string
# ---------------------------------------------------------------------------
array_to_json() {
    # Prints a JSON array from the given values passed as arguments.
    # Usage: array_to_json "${ARRAY[@]+"${ARRAY[@]}"}"
    #
    # Note: When called with zero arguments, `printf '%s\n'` still emits a
    # single newline (format-only case), which jq -R . would convert to "" and
    # jq -s . would wrap as [""]. Short-circuit to emit [] for empty input.
    if [ "$#" -eq 0 ]; then
        echo "[]"
        return 0
    fi
    printf '%s\n' "$@" | jq -R . | jq -s .
}

# ---------------------------------------------------------------------------
# Write manifest.json
# ---------------------------------------------------------------------------
write_manifest() {
    progress "Writing manifest.json..."

    local profile_val="${AWS_PROFILE:-}"
    local models_json agent_ids_json kb_ids_json gr_ids_json flow_ids_json
    local role_names_json ep_names_json ep_cfg_names_json trail_arns_json
    local pool_ids_json cm_ids_json lambda_names_json
    local ac_rt_ids_json ac_gw_ids_json ac_id_ids_json ac_mem_ids_json prompt_ids_json
    local errors_json

    # Dedup all arrays before writing
    dedup_array AGENT_IDS
    dedup_array KB_IDS
    dedup_array GUARDRAIL_IDS
    dedup_array FLOW_IDS
    dedup_array ROLE_NAMES
    dedup_array ENDPOINT_NAMES
    dedup_array ENDPOINT_CONFIG_NAMES
    dedup_array TRAIL_ARNS
    dedup_array USER_POOL_IDS
    dedup_array CUSTOM_MODEL_IDS
    dedup_array LAMBDA_NAMES
    dedup_array MODELS
    dedup_array AGENTCORE_RUNTIME_IDS
    dedup_array AGENTCORE_GATEWAY_IDS
    dedup_array AGENTCORE_IDENTITY_IDS
    dedup_array AGENTCORE_MEMORY_IDS
    dedup_array PROMPT_IDS
    dedup_array MODELS_NEEDING_RESOLUTION
    dedup_array INFERENCE_PROFILES

    agent_ids_json=$(array_to_json "${AGENT_IDS[@]+"${AGENT_IDS[@]}"}")
    kb_ids_json=$(array_to_json "${KB_IDS[@]+"${KB_IDS[@]}"}")
    gr_ids_json=$(array_to_json "${GUARDRAIL_IDS[@]+"${GUARDRAIL_IDS[@]}"}")
    flow_ids_json=$(array_to_json "${FLOW_IDS[@]+"${FLOW_IDS[@]}"}")
    role_names_json=$(array_to_json "${ROLE_NAMES[@]+"${ROLE_NAMES[@]}"}")
    ep_names_json=$(array_to_json "${ENDPOINT_NAMES[@]+"${ENDPOINT_NAMES[@]}"}")
    ep_cfg_names_json=$(array_to_json "${ENDPOINT_CONFIG_NAMES[@]+"${ENDPOINT_CONFIG_NAMES[@]}"}")
    trail_arns_json=$(array_to_json "${TRAIL_ARNS[@]+"${TRAIL_ARNS[@]}"}")
    pool_ids_json=$(array_to_json "${USER_POOL_IDS[@]+"${USER_POOL_IDS[@]}"}")
    cm_ids_json=$(array_to_json "${CUSTOM_MODEL_IDS[@]+"${CUSTOM_MODEL_IDS[@]}"}")
    lambda_names_json=$(array_to_json "${LAMBDA_NAMES[@]+"${LAMBDA_NAMES[@]}"}")
    models_json=$(array_to_json "${MODELS[@]+"${MODELS[@]}"}")
    ac_rt_ids_json=$(array_to_json "${AGENTCORE_RUNTIME_IDS[@]+"${AGENTCORE_RUNTIME_IDS[@]}"}")
    ac_gw_ids_json=$(array_to_json "${AGENTCORE_GATEWAY_IDS[@]+"${AGENTCORE_GATEWAY_IDS[@]}"}")
    ac_id_ids_json=$(array_to_json "${AGENTCORE_IDENTITY_IDS[@]+"${AGENTCORE_IDENTITY_IDS[@]}"}")
    ac_mem_ids_json=$(array_to_json "${AGENTCORE_MEMORY_IDS[@]+"${AGENTCORE_MEMORY_IDS[@]}"}")
    prompt_ids_json=$(array_to_json "${PROMPT_IDS[@]+"${PROMPT_IDS[@]}"}")

    # Build errors JSON array from AGENTCORE_CLI_ERRORS
    # Each entry is "family|operation|message"
    if [ "${#AGENTCORE_CLI_ERRORS[@]}" -eq 0 ]; then
        errors_json="[]"
    else
        errors_json="["
        local first=true
        local i=0
        while [ "$i" -lt "${#AGENTCORE_CLI_ERRORS[@]}" ]; do
            local entry="${AGENTCORE_CLI_ERRORS[$i]}"
            local err_family err_op err_msg
            err_family=$(echo "$entry" | cut -d'|' -f1)
            err_op=$(echo "$entry" | cut -d'|' -f2)
            err_msg=$(echo "$entry" | cut -d'|' -f3-)
            if [ "$first" = true ]; then
                first=false
            else
                errors_json="${errors_json},"
            fi
            errors_json="${errors_json}{\"family\":$(echo "$err_family" | jq -R .),\"operation\":$(echo "$err_op" | jq -R .),\"message\":$(echo "$err_msg" | jq -R .)}"
            i=$((i + 1))
        done
        errors_json="${errors_json}]"
    fi

    # Build models_needing_resolution JSON (flat string array)
    local models_needing_resolution_json
    models_needing_resolution_json=$(array_to_json "${MODELS_NEEDING_RESOLUTION[@]+"${MODELS_NEEDING_RESOLUTION[@]}"}")

    # Build agentcore_runtime_models JSON array from pipe-delimited entries:
    # runtime_id|model|source[|profile_id|profile_arn|underlying_arns]
    local agentcore_runtime_models_json
    if [ "${#AGENTCORE_RUNTIME_MODELS[@]}" -eq 0 ]; then
        agentcore_runtime_models_json="[]"
    else
        agentcore_runtime_models_json=$(printf '%s\n' "${AGENTCORE_RUNTIME_MODELS[@]}" | jq -R '
            split("|") |
            if length >= 6 then
                { runtime_id: .[0], model: .[1], source: .[2],
                  profile_id: .[3], profile_arn: .[4], underlying_arns: .[5] }
            elif length >= 3 then
                { runtime_id: .[0], model: .[1], source: .[2] }
            else
                { runtime_id: .[0], model: (.[1] // ""), source: "" }
            end
        ' | jq -s .)
    fi

    # Build bedrock_agent_models JSON array from pipe-delimited entries:
    # agent_id|model|source[|profile_id|profile_arn|underlying_arns]
    local bedrock_agent_models_json
    if [ "${#BEDROCK_AGENT_MODELS[@]}" -eq 0 ]; then
        bedrock_agent_models_json="[]"
    else
        bedrock_agent_models_json=$(printf '%s\n' "${BEDROCK_AGENT_MODELS[@]}" | jq -R '
            split("|") |
            if length >= 6 then
                { agent_id: .[0], model: .[1], source: .[2],
                  profile_id: .[3], profile_arn: .[4], underlying_arns: .[5] }
            elif length >= 3 then
                { agent_id: .[0], model: .[1], source: .[2] }
            else
                { agent_id: .[0], model: (.[1] // ""), source: "" }
            end
        ' | jq -s .)
    fi

    # Build inference_profiles JSON array from pipe-delimited entries:
    # id|arn|type|modelArn[,modelArn...]
    local inference_profiles_json
    if [ "${#INFERENCE_PROFILES[@]}" -eq 0 ]; then
        inference_profiles_json="[]"
    else
        inference_profiles_json=$(printf '%s\n' "${INFERENCE_PROFILES[@]}" | jq -R '
            split("|") |
            { id: .[0], arn: .[1], type: .[2],
              models: ((.[3] // "") | split(",") | map(select(. != "")) | map({modelArn: .})) }
        ' | jq -s .)
    fi

    jq -n \
        --arg account_id "$ACCOUNT_ID" \
        --arg region "$REGION" \
        --arg solution_name "$SOLUTION_NAME" \
        --arg identity_arn "$IDENTITY_ARN" \
        --arg profile "$profile_val" \
        --arg input_type "$INPUT_TYPE" \
        --arg discovery_date "$DISCOVERY_DATE" \
        --arg review_scope "$REVIEW_SCOPE" \
        --argjson agent_ids "$agent_ids_json" \
        --argjson kb_ids "$kb_ids_json" \
        --argjson guardrail_ids "$gr_ids_json" \
        --argjson flow_ids "$flow_ids_json" \
        --argjson role_names "$role_names_json" \
        --argjson endpoint_names "$ep_names_json" \
        --argjson endpoint_config_names "$ep_cfg_names_json" \
        --argjson trail_arns "$trail_arns_json" \
        --argjson user_pool_ids "$pool_ids_json" \
        --argjson custom_model_ids "$cm_ids_json" \
        --argjson lambda_names "$lambda_names_json" \
        --argjson models "$models_json" \
        --argjson agentcore_runtime_ids "$ac_rt_ids_json" \
        --argjson agentcore_gateway_ids "$ac_gw_ids_json" \
        --argjson agentcore_identity_ids "$ac_id_ids_json" \
        --argjson agentcore_memory_ids "$ac_mem_ids_json" \
        --argjson prompt_ids "$prompt_ids_json" \
        --argjson errors "$errors_json" \
        --argjson models_needing_resolution "$models_needing_resolution_json" \
        --argjson agentcore_runtime_models "$agentcore_runtime_models_json" \
        --argjson bedrock_agent_models "$bedrock_agent_models_json" \
        --argjson inference_profiles "$inference_profiles_json" \
        '{
            account_id: $account_id,
            region: $region,
            solution_name: $solution_name,
            identity_arn: $identity_arn,
            profile: $profile,
            input_type: $input_type,
            discovery_date: $discovery_date,
            review_scope: $review_scope,
            agent_ids: $agent_ids,
            kb_ids: $kb_ids,
            guardrail_ids: $guardrail_ids,
            flow_ids: $flow_ids,
            role_names: $role_names,
            endpoint_names: $endpoint_names,
            endpoint_config_names: $endpoint_config_names,
            trail_arns: $trail_arns,
            user_pool_ids: $user_pool_ids,
            custom_model_ids: $custom_model_ids,
            lambda_names: $lambda_names,
            models: $models,
            agentcore_runtime_ids: $agentcore_runtime_ids,
            agentcore_gateway_ids: $agentcore_gateway_ids,
            agentcore_identity_ids: $agentcore_identity_ids,
            agentcore_memory_ids: $agentcore_memory_ids,
            prompt_ids: $prompt_ids,
            models_needing_resolution: $models_needing_resolution,
            agentcore_runtime_models: $agentcore_runtime_models,
            bedrock_agent_models: $bedrock_agent_models,
            inference_profiles: $inference_profiles,
            errors: $errors
        }' > "$DATA_DIR/manifest.json"

    log_info "manifest.json written to ${DATA_DIR}/manifest.json"
}


# ---------------------------------------------------------------------------
# Write report.json skeleton
# ---------------------------------------------------------------------------
write_report_skeleton() {
    progress "Writing report.json skeleton..."

    local profile_display="${AWS_PROFILE:-default}"
    local input_type_display="$INPUT_TYPE"

    case "$INPUT_TYPE" in
        agent-arn)        input_type_display="Agent ARN" ;;
        stack-name)      input_type_display="CloudFormation Stack" ;;
        tf-state)        input_type_display="Terraform State" ;;
        app-arn)         input_type_display="AppRegistry Application" ;;
        resource-group)  input_type_display="Resource Group" ;;
        code-only)       input_type_display="Code Workspace" ;;
    esac

    # Build resource summary — include every resource type with a non-zero
    # count so the inventory line reflects the full solution footprint.
    local agent_count kb_count gr_count flow_count ep_count
    local lambda_count role_count pool_count trail_count cm_count
    local ac_rt_count ac_gw_count ac_id_count ac_mem_count prompt_count
    agent_count="${#AGENT_IDS[@]}"
    kb_count="${#KB_IDS[@]}"
    gr_count="${#GUARDRAIL_IDS[@]}"
    flow_count="${#FLOW_IDS[@]}"
    ep_count="${#ENDPOINT_NAMES[@]}"
    lambda_count="${#LAMBDA_NAMES[@]}"
    role_count="${#ROLE_NAMES[@]}"
    pool_count="${#USER_POOL_IDS[@]}"
    trail_count="${#TRAIL_ARNS[@]}"
    cm_count="${#CUSTOM_MODEL_IDS[@]}"
    ac_rt_count="${#AGENTCORE_RUNTIME_IDS[@]}"
    ac_gw_count="${#AGENTCORE_GATEWAY_IDS[@]}"
    ac_id_count="${#AGENTCORE_IDENTITY_IDS[@]}"
    ac_mem_count="${#AGENTCORE_MEMORY_IDS[@]}"
    prompt_count="${#PROMPT_IDS[@]}"

    local summary_parts=""
    _append_part() {
        local count="$1"
        local label="$2"
        if [ "$count" -gt 0 ]; then
            if [ -z "$summary_parts" ]; then
                summary_parts="${count} ${label}"
            else
                summary_parts="${summary_parts}, ${count} ${label}"
            fi
        fi
    }
    _append_part "$agent_count"  "Bedrock Agent(s)"
    _append_part "$kb_count"     "Knowledge Base(s)"
    _append_part "$gr_count"     "Guardrail(s)"
    _append_part "$flow_count"   "Flow(s)"
    _append_part "$cm_count"     "Custom Model(s)"
    _append_part "$ep_count"     "SageMaker Endpoint(s)"
    _append_part "$lambda_count" "Lambda Function(s)"
    _append_part "$role_count"   "IAM Role(s)"
    _append_part "$pool_count"   "Cognito User Pool(s)"
    _append_part "$trail_count"  "CloudTrail Trail(s)"
    _append_part "$ac_rt_count"  "AgentCore Runtime(s)"
    _append_part "$ac_gw_count"  "AgentCore Gateway(s)"
    _append_part "$ac_id_count"  "AgentCore Identity(s)"
    _append_part "$ac_mem_count" "AgentCore Memory Store(s)"
    _append_part "$prompt_count" "Prompt(s)"

    local resource_summary="${summary_parts:-No resources discovered}"

    # Models as a JSON array.
    local models_json="[]"
    if [ "${#MODELS[@]}" -gt 0 ]; then
        models_json=$(printf '%s\n' "${MODELS[@]+"${MODELS[@]}"}" | jq -R . | jq -s .)
    fi

    # Frameworks as a JSON array (canonical case matching registry).
    # Input forms: "wa", "nist", "finops", "all", or comma-separated combos.
    local frameworks_json
    frameworks_json=$(echo "$FRAMEWORKS" | tr ',' '\n' | awk '
      { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0=="") next
        if      (tolower($0)=="wa")     print "WA"
        else if (tolower($0)=="nist")   print "NIST"
        else if (tolower($0)=="finops") print "FinOps"
        else if (tolower($0)=="all")    { print "WA"; print "NIST"; print "FinOps" }
        else print
      }
    ' | jq -R . | jq -s 'unique')

    jq -n \
        --arg solution_name     "$SOLUTION_NAME" \
        --arg region            "$REGION" \
        --arg account_id        "$ACCOUNT_ID" \
        --arg profile           "$profile_display" \
        --arg identity_arn      "$IDENTITY_ARN" \
        --arg input_type        "$input_type_display" \
        --arg resources_summary "$resource_summary" \
        --argjson models        "$models_json" \
        --arg review_date       "$DISCOVERY_DATE" \
        --arg review_scope      "$REVIEW_SCOPE" \
        --argjson frameworks    "$frameworks_json" \
        '{
            metadata: {
                solution_name: $solution_name,
                region: $region,
                account_id: $account_id,
                profile: $profile,
                identity_arn: $identity_arn,
                input_type: $input_type,
                resources_summary: $resources_summary,
                models: $models,
                review_date: $review_date,
                review_scope: $review_scope,
                frameworks: $frameworks
            },
            executive_summary: {
                prose: "",
                strengths: [],
                critical_high_findings: []
            },
            findings: []
        }' > "$DATA_DIR/report.json"

    log_info "report.json skeleton written to ${DATA_DIR}/report.json"
}

# ---------------------------------------------------------------------------
# Authorization-error halt check (Requirement 3.6)
# ---------------------------------------------------------------------------
# Scans COLLECTED_ERRORS for authorization errors (AccessDeniedException,
# UnauthorizedException, ExpiredTokenException). If found, writes the halt
# file, prints the family + operation + error to stdout, and exits 4.
#
# Only called for scoped inputs (agent-arn, stack-name, app-arn).
check_authz_halt() {
    local count="${#COLLECTED_ERRORS[@]}"
    [ "$count" -eq 0 ] && return 0

    local i=0
    while [ "$i" -lt "$count" ]; do
        local err="${COLLECTED_ERRORS[$i]}"
        # Match only the three authorization error types
        if echo "$err" | grep -qE 'AccessDeniedException|UnauthorizedException|ExpiredTokenException'; then
            # Extract the failing operation from the error string.
            # Error format from retry_cmd: "Non-retryable error running: <cmd> — <output>"
            local failed_op=""
            local error_msg=""
            local family=""

            # Parse command string: text between "running: " and " — "
            failed_op=$(echo "$err" | sed -n 's/.*running: \(.*\) — .*/\1/p')
            # Parse error message: text after " — "
            error_msg=$(echo "$err" | sed -n 's/.*— \(.*\)/\1/p')

            # Derive family from the AWS CLI service name in the command
            # (e.g., "aws bedrock-agent get-agent ..." → "bedrock-agent")
            if [ -n "$failed_op" ]; then
                family=$(echo "$failed_op" | awk '{for(j=1;j<=NF;j++){if($j=="aws"){print $(j+1); exit}}}')
            fi
            [ -z "$family" ] && family="unknown"
            [ -z "$failed_op" ] && failed_op="unknown"
            [ -z "$error_msg" ] && error_msg="$err"

            # Determine scope value
            local scope_value=""
            case "$INPUT_TYPE" in
                agent-arn)       scope_value="agent-arn:${AGENT_ARN}" ;;
                stack-name)     scope_value="stack-name:${STACK_NAME}" ;;
                tf-state)       scope_value="tf-state:${TF_STATE_DIR}" ;;
                app-arn)        scope_value="app-arn:${APP_ARN}" ;;
                resource-group) scope_value="resource-group:${RESOURCE_GROUP}" ;;
            esac

            # Write discovery-halt.txt
            cat > "${DATA_DIR}/discovery-halt.txt" <<EOF
HALT_REASON=authz-error
SCOPE=${scope_value}
FAMILIES_QUERIED=AGENT_IDS,KB_IDS,GUARDRAIL_IDS,AGENTCORE_RUNTIME_IDS,AGENTCORE_GATEWAY_IDS,AGENTCORE_IDENTITY_IDS,AGENTCORE_MEMORY_IDS,PROMPT_IDS
FAILED_OPERATION=${failed_op}
ERROR_MESSAGE=${error_msg}
EOF

            # Print family + operation + error to stdout
            printf 'Authorization error — family: %s, operation: %s, error: %s\n' \
                "$family" "$failed_op" "$error_msg"

            exit 4
        fi
        i=$((i + 1))
    done

    return 0
}


# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
main() {
    # Determine discovery path
    if [ -n "$AGENT_ARN" ]; then
        INPUT_TYPE="agent-arn"
        discover_agent_arn
    elif [ -n "$STACK_NAME" ]; then
        INPUT_TYPE="stack-name"
        discover_cfn_stack "$STACK_NAME"
    elif [ -n "$TF_STATE_DIR" ]; then
        INPUT_TYPE="tf-state"
        discover_terraform_state
    elif [ -n "$APP_ARN" ]; then
        INPUT_TYPE="app-arn"
        discover_app_registry
    elif [ -n "$RESOURCE_GROUP" ]; then
        INPUT_TYPE="resource-group"
        discover_resource_group
    else
        # Code-only mode
        INPUT_TYPE="code-only"
        ACCOUNT_ID="N/A"
        IDENTITY_ARN="N/A"
        progress "Running in code-only mode (no cloud input source provided)"
        log_info "Code-only mode: all resource arrays will be empty"
    fi

    # --- Authorization-error halt check (Requirement 3.6) ---
    # Check before zero-resource halt; auth errors are more actionable.
    if [ "$INPUT_TYPE" != "code-only" ]; then
        check_authz_halt
    fi

    # --- Zero-resource halt check (Requirement 3.5) ---
    # Compute TOTAL_DISCOVERED across the 8 primary families only (excludes
    # FLOW_IDS, ENDPOINT_NAMES, and other auxiliary families).
    local TOTAL_DISCOVERED
    TOTAL_DISCOVERED=$(( ${#AGENT_IDS[@]} + ${#KB_IDS[@]} + ${#GUARDRAIL_IDS[@]} + \
                         ${#AGENTCORE_RUNTIME_IDS[@]} + ${#AGENTCORE_GATEWAY_IDS[@]} + \
                         ${#AGENTCORE_IDENTITY_IDS[@]} + ${#AGENTCORE_MEMORY_IDS[@]} + \
                         ${#PROMPT_IDS[@]} ))

    if [ "$INPUT_TYPE" != "code-only" ] && [ "$TOTAL_DISCOVERED" -eq 0 ]; then
        # Determine scope value for the halt manifest
        local scope_value=""
        case "$INPUT_TYPE" in
            agent-arn)       scope_value="agent-arn:${AGENT_ARN}" ;;
            stack-name)     scope_value="stack-name:${STACK_NAME}" ;;
            tf-state)       scope_value="tf-state:${TF_STATE_DIR}" ;;
            app-arn)        scope_value="app-arn:${APP_ARN}" ;;
            resource-group) scope_value="resource-group:${RESOURCE_GROUP}" ;;
        esac

        # Write discovery-halt.txt
        cat > "${DATA_DIR}/discovery-halt.txt" <<EOF
HALT_REASON=zero-resource
SCOPE=${scope_value}
FAMILIES_QUERIED=AGENT_IDS,KB_IDS,GUARDRAIL_IDS,AGENTCORE_RUNTIME_IDS,AGENTCORE_GATEWAY_IDS,AGENTCORE_IDENTITY_IDS,AGENTCORE_MEMORY_IDS,PROMPT_IDS
EOF

        # User-facing message
        printf 'No resources found in scope %s across all 8 primary families; halting before assessment.\n' "$scope_value"

        exit 3
    fi

    # WA lens pull is deprecated (no-op) — check definitions live in
    # ${SKILL_ROOT}/references/ and are loaded directly by the framework
    # scripts and the merge-findings helper.

    # --- Inference-profile discovery (R3.2, R3.9, R3.12) ---
    # Gather inference profiles once (account-wide) before any per-component
    # resolution needs them. Only runs when we have live AWS access.
    if [ "$INPUT_TYPE" != "code-only" ]; then
        progress "Discovering Bedrock inference profiles..."
        local ip_file="$RAW_DATA_DIR/bedrock-list-inference-profiles.json"
        fetch_or_cache "$ip_file" \
            aws bedrock list-inference-profiles \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

        if check_result "$ip_file"; then
            while IFS= read -r row; do
                [ -n "$row" ] && INFERENCE_PROFILES+=("$row")
            done <<< "$(jq -r '
                .inferenceProfileSummaries[]?
                | [ .inferenceProfileId, .inferenceProfileArn, .type,
                    ([.models[]?.modelArn] | join(",")) ]
                | @tsv' "$ip_file" 2>/dev/null | tr "\t" "|")"
        fi
        log_info "Inference profiles discovered: ${#INFERENCE_PROFILES[@]}"
    fi

    # --- AgentCore runtime model resolution (R3.1, R3.3, R3.4, R3.10, R3.12) ---
    # Dedup runtime IDs first, then resolve the foundation model for each
    # runtime via the priority chain: inference profile → direct CLI field.
    # Runtimes that cannot be resolved are placed on MODELS_NEEDING_RESOLUTION[].
    dedup_array AGENTCORE_RUNTIME_IDS

    if [ "${#AGENTCORE_RUNTIME_IDS[@]}" -gt 0 ] && [ "$INPUT_TYPE" != "code-only" ]; then
        progress "Resolving AgentCore runtime models (${#AGENTCORE_RUNTIME_IDS[@]} runtime(s))..."
        local rt_idx=0
        while [ "$rt_idx" -lt "${#AGENTCORE_RUNTIME_IDS[@]}" ]; do
            local rt_id="${AGENTCORE_RUNTIME_IDS[$rt_idx]}"
            local rt_detail_file="$RAW_DATA_DIR/bedrock-agentcore-control-get-agent-runtime-${rt_id}.json"
            fetch_or_cache "$rt_detail_file" \
                aws bedrock-agentcore-control get-agent-runtime \
                    --agent-runtime-id "$rt_id" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json

            if check_result "$rt_detail_file"; then
                # Extract cfg_model: prefer inferenceProfileArn, then inferenceProfileId,
                # then modelId, then foundationModel.
                local cfg_model
                cfg_model=$(jq -r '.inferenceProfileArn // .inferenceProfileId // .modelId // .foundationModel // empty' \
                    "$rt_detail_file" 2>/dev/null || true)

                # Extract direct_fm: prefer foundationModel, then modelId.
                local direct_fm
                direct_fm=$(jq -r '.foundationModel // .modelId // empty' \
                    "$rt_detail_file" 2>/dev/null || true)

                local resolved rc
                resolved=$(resolve_component_model "$cfg_model" "$direct_fm") && rc=0 || rc=$?
                if [ "$rc" -eq 0 ] && [ -n "$resolved" ]; then
                    local resolved_model
                    resolved_model=$(printf '%s' "$resolved" | cut -d'|' -f1)
                    [ -n "$resolved_model" ] && MODELS+=("$resolved_model")
                    AGENTCORE_RUNTIME_MODELS+=("${rt_id}|${resolved}")
                else
                    # Fallback: extract model IDs from environmentVariables keys
                    # matching *MODEL* (e.g. BEDROCK_MODEL_ID, BEDROCK_CART_MODEL_ID).
                    local env_models
                    env_models=$(jq -r '
                        .environmentVariables // {} | to_entries[]
                        | select(.key | test("MODEL"; "i"))
                        | select(.value | test("^(us\\.|eu\\.|ap\\.|[a-z]+\\.[a-z])"))
                        | .value
                    ' "$rt_detail_file" 2>/dev/null || true)
                    if [ -n "$env_models" ]; then
                        while IFS= read -r env_mid; do
                            [ -z "$env_mid" ] && continue
                            MODELS+=("$env_mid")
                            AGENTCORE_RUNTIME_MODELS+=("${rt_id}|${env_mid}|code")
                        done <<< "$env_models"
                    else
                        MODELS_NEEDING_RESOLUTION+=("$rt_id")
                    fi
                fi
            else
                # Could not fetch runtime details — mark as needing resolution
                MODELS_NEEDING_RESOLUTION+=("$rt_id")
            fi
            rt_idx=$((rt_idx + 1))
        done
        log_info "AgentCore runtime models resolved: ${#AGENTCORE_RUNTIME_MODELS[@]}, needing resolution: ${#MODELS_NEEDING_RESOLUTION[@]}"
    fi

    # Write manifest and report skeleton
    write_manifest
    write_report_skeleton

    # Purge any stale out-of-scope artifacts that may be lingering in data/
    # from a previous run against a different solution. Today this scrubs
    # AgentCore raw-data files when no AgentCore resources were discovered
    # in the current scope, preventing them from being silently re-served
    # by fetch_or_cache or browsed as if they belonged to this review.
    manifest_load_resource_ids "$DATA_DIR"
    purge_out_of_scope_data "$DATA_DIR"

    # Report completion
    local total_resources
    total_resources=$(( ${#AGENT_IDS[@]} + ${#KB_IDS[@]} + ${#GUARDRAIL_IDS[@]} + \
                        ${#FLOW_IDS[@]} + ${#ENDPOINT_NAMES[@]} + ${#CUSTOM_MODEL_IDS[@]} + \
                        ${#AGENTCORE_RUNTIME_IDS[@]} + ${#AGENTCORE_GATEWAY_IDS[@]} + \
                        ${#AGENTCORE_IDENTITY_IDS[@]} + ${#AGENTCORE_MEMORY_IDS[@]} + \
                        ${#PROMPT_IDS[@]} ))
    progress "Discovery complete: ${total_resources} resource(s) found across all types"

    # Flush collected errors and determine exit code
    print_errors; err_count=$?

    # LAST line of stdout must be the data directory path (agent captures this)
    echo "$DATA_DIR"

    if [ "$err_count" -gt 0 ]; then
        exit 2
    fi
    exit 0
}

main

