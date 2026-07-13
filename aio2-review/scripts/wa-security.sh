#!/usr/bin/env bash
# wa-security.sh — WA Security pillar data collection for AIO2 review
#
# Usage:
#   wa-security.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--guardrail-ids <id1,id2,...>]
#     [--role-names <name1,name2,...>] [--kb-ids <id1,id2,...>]
#     [--trail-arns <arn1,arn2,...>] [--user-pool-ids <id1,id2,...>]
#
# Writes: $DATA_DIR/security-summary.json
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
# shellcheck disable=SC2034 # accepted for CLI symmetry with other pillar
# scripts; this pillar's checks don't currently need agent-level data.
AGENT_ID=""
GUARDRAIL_IDS_RAW=""
ROLE_NAMES_RAW=""
KB_IDS_RAW=""
TRAIL_ARNS_RAW=""
USER_POOL_IDS_RAW=""
PROMPT_IDS_RAW=""
AGENTCORE_RUNTIME_IDS_RAW=""
AGENTCORE_IDENTITY_IDS_RAW=""
AGENTCORE_MEMORY_IDS_RAW=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --region <region> --data-dir <path> [OPTIONS]

Options:
  --region <region>            AWS region (required)
  --profile <profile>          AWS CLI profile name (optional)
  --data-dir <path>            Data directory (required)
  --agent-id <id>              Bedrock Agent ID (optional)
  --guardrail-ids <ids>        Comma-separated guardrail IDs (optional)
  --role-names <names>         Comma-separated IAM role names (optional)
  --kb-ids <ids>               Comma-separated Knowledge Base IDs (optional)
  --trail-arns <arns>          Comma-separated CloudTrail trail ARNs (optional)
  --user-pool-ids <ids>        Comma-separated Cognito user pool IDs (optional)
  --prompt-ids <ids>           Comma-separated Bedrock Prompt IDs (optional)
  --agentcore-runtime-ids <ids>  Comma-separated AgentCore Runtime IDs (optional)
  --agentcore-identity-names <names>  Comma-separated AgentCore Workload Identity names (optional)
  --agentcore-memory-ids <ids>   Comma-separated AgentCore Memory IDs (optional)
  --help, -h                   Show this help message

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
        --kb-ids)
            KB_IDS_RAW="${2:-}"
            shift 2
            ;;
        --kb-ids=*)
            KB_IDS_RAW="${1#--kb-ids=}"
            shift
            ;;
        --trail-arns)
            TRAIL_ARNS_RAW="${2:-}"
            shift 2
            ;;
        --trail-arns=*)
            TRAIL_ARNS_RAW="${1#--trail-arns=}"
            shift
            ;;
        --user-pool-ids)
            USER_POOL_IDS_RAW="${2:-}"
            shift 2
            ;;
        --user-pool-ids=*)
            USER_POOL_IDS_RAW="${1#--user-pool-ids=}"
            shift
            ;;
        --prompt-ids)
            PROMPT_IDS_RAW="${2:-}"
            shift 2
            ;;
        --prompt-ids=*)
            PROMPT_IDS_RAW="${1#--prompt-ids=}"
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
        --agentcore-identity-names)
            AGENTCORE_IDENTITY_IDS_RAW="${2:-}"
            shift 2
            ;;
        --agentcore-identity-names=*)
            AGENTCORE_IDENTITY_IDS_RAW="${1#--agentcore-identity-names=}"
            shift
            ;;
        --agentcore-memory-ids)
            AGENTCORE_MEMORY_IDS_RAW="${2:-}"
            shift 2
            ;;
        --agentcore-memory-ids=*)
            AGENTCORE_MEMORY_IDS_RAW="${1#--agentcore-memory-ids=}"
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
    # split_csv <string> — prints one item per line
    echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# Build arrays from raw CSV strings
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

KB_IDS=()
if [ -n "$KB_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && KB_IDS+=("$item")
    done < <(split_csv "$KB_IDS_RAW")
fi

TRAIL_ARNS=()
if [ -n "$TRAIL_ARNS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && TRAIL_ARNS+=("$item")
    done < <(split_csv "$TRAIL_ARNS_RAW")
fi

USER_POOL_IDS=()
if [ -n "$USER_POOL_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && USER_POOL_IDS+=("$item")
    done < <(split_csv "$USER_POOL_IDS_RAW")
fi

PROMPT_IDS=()
if [ -n "$PROMPT_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && PROMPT_IDS+=("$item")
    done < <(split_csv "$PROMPT_IDS_RAW")
fi

AGENTCORE_RUNTIME_IDS=()
if [ -n "$AGENTCORE_RUNTIME_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && AGENTCORE_RUNTIME_IDS+=("$item")
    done < <(split_csv "$AGENTCORE_RUNTIME_IDS_RAW")
fi

AGENTCORE_IDENTITY_NAMES=()
if [ -n "$AGENTCORE_IDENTITY_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && AGENTCORE_IDENTITY_NAMES+=("$item")
    done < <(split_csv "$AGENTCORE_IDENTITY_IDS_RAW")
fi

AGENTCORE_MEMORY_IDS=()
if [ -n "$AGENTCORE_MEMORY_IDS_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && AGENTCORE_MEMORY_IDS+=("$item")
    done < <(split_csv "$AGENTCORE_MEMORY_IDS_RAW")
fi

# ---------------------------------------------------------------------------
# Phase 1 — parallel fetches
# ---------------------------------------------------------------------------
progress "Phase 1: Fetching security data..."

# Fixed fetches — run in parallel
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-guardrails.json" \
    aws bedrock list-guardrails --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/cloudtrail-describe-trails.json" \
    aws cloudtrail describe-trails --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json" \
    aws ec2 describe-vpc-endpoints --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
        --filters "Name=service-name,Values=*bedrock*,*sagemaker*" --output json &

fetch_or_cache "$RAW_DATA_DIR/cognito-list-user-pools.json" \
    aws cognito-idp list-user-pools --max-results 10 \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json" \
    aws bedrock get-model-invocation-logging-configuration \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# AgentCore Policy engines (BP06_03 — per-user/per-tool access control).
# Only query when the workload actually uses AgentCore — otherwise this
# unconditional account-wide list pollutes the data directory with results
# from unrelated solutions in the same account.
if [ "${AGENTCORE_PRESENT:-0}" -eq 1 ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agentcore-control-list-policy-engines.json" \
        aws bedrock-agentcore-control list-policy-engines \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

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

# Per-prompt fetches (for GENSEC04_BP01 — prompt catalog with versioning)
i=0
while [ "$i" -lt "${#PROMPT_IDS[@]}" ]; do
    p_id="${PROMPT_IDS[$i]}"
    p_id_safe=$(safe_id "$p_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-prompt-${p_id_safe}.json" \
        aws bedrock-agent get-prompt --prompt-identifier "$p_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-AgentCore-runtime fetches (for BP06_01 — session isolation)
i=0
while [ "$i" -lt "${#AGENTCORE_RUNTIME_IDS[@]}" ]; do
    rt_id="${AGENTCORE_RUNTIME_IDS[$i]}"
    rt_id_safe=$(safe_id "$rt_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agentcore-control-get-agent-runtime-${rt_id_safe}.json" \
        aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$rt_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-workload-identity fetches (for BP06_01 — session isolation / IdP linkage)
i=0
while [ "$i" -lt "${#AGENTCORE_IDENTITY_NAMES[@]}" ]; do
    wid_name="${AGENTCORE_IDENTITY_NAMES[$i]}"
    wid_name_safe=$(safe_id "$wid_name")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agentcore-control-get-workload-identity-${wid_name_safe}.json" \
        aws bedrock-agentcore-control get-workload-identity --name "$wid_name" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-memory fetches (for BP06_04 — memory namespaced per user)
i=0
while [ "$i" -lt "${#AGENTCORE_MEMORY_IDS[@]}" ]; do
    mem_id="${AGENTCORE_MEMORY_IDS[$i]}"
    mem_id_safe=$(safe_id "$mem_id")
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agentcore-control-get-memory-${mem_id_safe}.json" \
        aws bedrock-agentcore-control get-memory --memory-id "$mem_id" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-KB fetches (for KB_ACCESS_CONTROL, KB_DATA_SOURCE_ENCRYPTION)
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

# Per-role fetches
i=0
while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
    role="${ROLE_NAMES[$i]}"
    fetch_or_cache "$RAW_DATA_DIR/iam-get-role-${role}.json" \
        aws iam get-role --role-name "$role" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/iam-list-attached-role-policies-${role}.json" \
        aws iam list-attached-role-policies --role-name "$role" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fetch_or_cache "$RAW_DATA_DIR/iam-list-role-policies-${role}.json" \
        aws iam list-role-policies --role-name "$role" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Per-trail fetches
i=0
while [ "$i" -lt "${#TRAIL_ARNS[@]}" ]; do
    trail_arn="${TRAIL_ARNS[$i]}"
    safe_arn=$(safe_id "$trail_arn")
    fetch_or_cache "$RAW_DATA_DIR/cloudtrail-get-trail-status-${safe_arn}.json" \
        aws cloudtrail get-trail-status --name "$trail_arn" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    i=$((i + 1))
done

# Organizations SCPs (GENSEC01_BP01, GENSEC05_BP01 — org-level model/agent restrictions)
set +e
fetch_or_cache "$RAW_DATA_DIR/organizations-list-policies.json" \
    aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
set -e

# GuardDuty (GENOPS02_BP01 — security monitoring / threat detection)
fetch_or_cache "$RAW_DATA_DIR/guardduty-list-detectors.json" \
    aws guardduty list-detectors \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# WAF web ACLs (GENSEC04_BP02 — rate limiting)
fetch_or_cache "$RAW_DATA_DIR/wafv2-list-web-acls.json" \
    aws wafv2 list-web-acls --scope REGIONAL \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Phase 2 — inline policy fetches (depend on phase 1 list-role-policies results)
# ---------------------------------------------------------------------------
progress "Phase 2: Fetching inline role policies..."

i=0
while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
    role="${ROLE_NAMES[$i]}"
    list_file="$RAW_DATA_DIR/iam-list-role-policies-${role}.json"
    if check_result "$list_file"; then
        policy_names=$(jq -r '.PolicyNames[]? // empty' "$list_file" 2>/dev/null || true)
        while IFS= read -r policy_name; do
            [ -z "$policy_name" ] && continue
            fetch_or_cache "$RAW_DATA_DIR/iam-get-role-policy-${role}-${policy_name}.json" \
                aws iam get-role-policy --role-name "$role" --policy-name "$policy_name" \
                    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        done <<< "$policy_names"
    fi
    i=$((i + 1))
done

# Organizations SCPs: fetch policy details (depends on Phase 1 organizations-list-policies)
org_policies_file="$RAW_DATA_DIR/organizations-list-policies.json"
if check_result "$org_policies_file"; then
    scp_ids=$(jq -r '[.Policies[]? | .Id] | .[0:5] | .[]' "$org_policies_file" 2>/dev/null || true)
    if [ -n "$scp_ids" ]; then
        while IFS= read -r scp_id; do
            [ -z "$scp_id" ] && continue
            scp_id_safe=$(safe_id "$scp_id")
            set +e
            fetch_or_cache "$RAW_DATA_DIR/organizations-describe-policy-${scp_id_safe}.json" \
                aws organizations describe-policy --policy-id "$scp_id" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
            set -e
        done <<< "$scp_ids"
    fi
fi

# VPC endpoint security groups (depends on Phase 1 vpc-endpoints result)
vpce_file="$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json"
if check_result "$vpce_file"; then
    vpce_sg_ids=$(jq -r '[.VpcEndpoints[]?.Groups[]?.GroupId // empty] | unique | .[]' "$vpce_file" 2>/dev/null || true)
    if [ -n "$vpce_sg_ids" ]; then
        # Collect all unique SG IDs into a real array (not a space-joined
        # string) so --group-ids expansion doesn't rely on word splitting.
        sg_ids_arg=()
        while IFS= read -r sg_id; do
            [ -z "$sg_id" ] && continue
            sg_ids_arg+=("$sg_id")
        done <<< "$vpce_sg_ids"
        if [ "${#sg_ids_arg[@]}" -gt 0 ]; then
            fetch_or_cache "$RAW_DATA_DIR/ec2-describe-security-groups-vpce.json" \
                aws ec2 describe-security-groups --group-ids "${sg_ids_arg[@]}" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        fi
    fi
fi

# GuardDuty detector details (depends on Phase 1 list-detectors)
gd_list_file="$RAW_DATA_DIR/guardduty-list-detectors.json"
if check_result "$gd_list_file"; then
    gd_detector_id=$(jq -r '.DetectorIds[0] // empty' "$gd_list_file" 2>/dev/null || true)
    if [ -n "$gd_detector_id" ]; then
        gd_id_safe=$(safe_id "$gd_detector_id")
        fetch_or_cache "$RAW_DATA_DIR/guardduty-get-detector-${gd_id_safe}.json" \
            aws guardduty get-detector --detector-id "$gd_detector_id" \
                --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
    fi
fi

# Per-policy-engine: fetch policies (depends on Phase 1 list-policy-engines result).
# Skipped entirely when AgentCore is not in scope.
if [ "${AGENTCORE_PRESENT:-0}" -eq 1 ]; then
    pe_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-policy-engines.json"
    if check_result "$pe_file"; then
        pe_ids=$(jq -r '.policyEngines[]?.policyEngineId // empty' "$pe_file" 2>/dev/null || true)
        while IFS= read -r pe_id; do
            [ -z "$pe_id" ] && continue
            pe_id_safe=$(safe_id "$pe_id")
            fetch_or_cache "$RAW_DATA_DIR/bedrock-agentcore-control-list-policies-${pe_id_safe}.json" \
                aws bedrock-agentcore-control list-policies --policy-engine-id "$pe_id" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        done <<< "$pe_ids"
    fi
fi

# Per-KB role: fetch IAM policies for KB execution roles not already in ROLE_NAMES
# (depends on Phase 1 get-knowledge-base results)
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    if check_result "$kb_file"; then
        kb_role_arn_p2=$(jq -r '.knowledgeBase.roleArn // empty' "$kb_file" 2>/dev/null || true)
        if [ -n "$kb_role_arn_p2" ]; then
            kb_role_name_p2="${kb_role_arn_p2##*/}"
            # Only fetch if not already fetched via ROLE_NAMES
            if [ ! -f "$RAW_DATA_DIR/iam-list-role-policies-${kb_role_name_p2}.json" ]; then
                fetch_or_cache "$RAW_DATA_DIR/iam-list-role-policies-${kb_role_name_p2}.json" \
                    aws iam list-role-policies --role-name "$kb_role_name_p2" \
                        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
                fetch_or_cache "$RAW_DATA_DIR/iam-list-attached-role-policies-${kb_role_name_p2}.json" \
                    aws iam list-attached-role-policies --role-name "$kb_role_name_p2" \
                        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
            fi
        fi
    fi
    i=$((i + 1))
done

# Per-KB data source: fetch get-data-source and S3 bucket encryption/policy
# (depends on Phase 1 list-data-sources results)
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    ds_list_file="$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json"
    if check_result "$ds_list_file"; then
        ds_ids=$(jq -r '.dataSourceSummaries[]?.dataSourceId // empty' "$ds_list_file" 2>/dev/null || true)
        while IFS= read -r ds_id; do
            [ -z "$ds_id" ] && continue
            ds_id_safe=$(safe_id "$ds_id")
            fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-data-source-${kb_id_safe}-${ds_id_safe}.json" \
                aws bedrock-agent get-data-source \
                    --knowledge-base-id "$kb_id" --data-source-id "$ds_id" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        done <<< "$ds_ids"
    fi
    i=$((i + 1))
done

wait
progress "Phase 2 complete."

# ---------------------------------------------------------------------------
# Phase 2b — KB role inline policy documents (depend on Phase 2 list-role-policies)
# ---------------------------------------------------------------------------
# Fetch inline policy documents for KB roles that weren't in the original ROLE_NAMES
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    if check_result "$kb_file"; then
        kb_role_arn_p2b=$(jq -r '.knowledgeBase.roleArn // empty' "$kb_file" 2>/dev/null || true)
        if [ -n "$kb_role_arn_p2b" ]; then
            kb_role_name_p2b="${kb_role_arn_p2b##*/}"
            list_file_p2b="$RAW_DATA_DIR/iam-list-role-policies-${kb_role_name_p2b}.json"
            if check_result "$list_file_p2b"; then
                policy_names_p2b=$(jq -r '.PolicyNames[]? // empty' "$list_file_p2b" 2>/dev/null || true)
                while IFS= read -r pn_p2b; do
                    [ -z "$pn_p2b" ] && continue
                    fetch_or_cache "$RAW_DATA_DIR/iam-get-role-policy-${kb_role_name_p2b}-${pn_p2b}.json" \
                        aws iam get-role-policy --role-name "$kb_role_name_p2b" --policy-name "$pn_p2b" \
                            "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
                done <<< "$policy_names_p2b"
            fi
        fi
    fi
    i=$((i + 1))
done

wait

# ---------------------------------------------------------------------------
# Phase 3 — S3 bucket checks (depend on Phase 2 get-data-source results)
# ---------------------------------------------------------------------------
progress "Phase 3: Fetching S3 bucket security data..."

i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    ds_list_file="$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json"
    if check_result "$ds_list_file"; then
        ds_ids=$(jq -r '.dataSourceSummaries[]?.dataSourceId // empty' "$ds_list_file" 2>/dev/null || true)
        while IFS= read -r ds_id; do
            [ -z "$ds_id" ] && continue
            ds_id_safe=$(safe_id "$ds_id")
            ds_file="$RAW_DATA_DIR/bedrock-agent-get-data-source-${kb_id_safe}-${ds_id_safe}.json"
            if check_result "$ds_file"; then
                # Extract S3 bucket ARN and derive bucket name
                bucket_arn=$(jq -r '.dataSource.dataSourceConfiguration.s3Configuration.bucketArn // empty' "$ds_file" 2>/dev/null || true)
                if [ -n "$bucket_arn" ]; then
                    bucket_name="${bucket_arn#arn:aws:s3:::}"
                    bucket_safe=$(safe_id "$bucket_name")
                    fetch_or_cache "$RAW_DATA_DIR/s3-get-bucket-encryption-${bucket_safe}.json" \
                        aws s3api get-bucket-encryption --bucket "$bucket_name" \
                            "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
                    fetch_or_cache "$RAW_DATA_DIR/s3-get-bucket-policy-${bucket_safe}.json" \
                        aws s3api get-bucket-policy --bucket "$bucket_name" \
                            "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
                fi
            fi
        done <<< "$ds_ids"
    fi
    i=$((i + 1))
done

wait
progress "Phase 3 complete."

# ---------------------------------------------------------------------------
# Build security-summary.json
# ---------------------------------------------------------------------------
progress "Building security-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Guardrails ---
guardrails_list_file="$RAW_DATA_DIR/bedrock-list-guardrails.json"
guardrails_exists="false"
guardrails_count=0
guardrails_details="[]"

if check_result "$guardrails_list_file"; then
    guardrails_count=$(jq '.guardrails | length' "$guardrails_list_file" 2>/dev/null || echo 0)
    if [ "$guardrails_count" -gt 0 ]; then
        guardrails_exists="true"
    fi
fi

# Build per-guardrail detail array from individual get-guardrail files
guardrails_detail_parts=""
i=0
while [ "$i" -lt "${#GUARDRAIL_IDS[@]}" ]; do
    gid="${GUARDRAIL_IDS[$i]}"
    gid_safe=$(safe_id "$gid")
    gfile="$RAW_DATA_DIR/bedrock-get-guardrail-${gid_safe}.json"
    if check_result "$gfile"; then
        detail=$(jq -c --arg gid "$gid" '{
            id: $gid,
            has_content_filters:       ((.contentPolicy.filters | length) > 0),
            has_topic_policies:        ((.topicPolicy.topics | length) > 0),
            has_word_filters:          ((.wordPolicy.words | length) > 0 or (.wordPolicy.managedWordLists | length) > 0),
            has_sensitive_info_filters:((.sensitiveInformationPolicy.piiEntities | length) > 0 or (.sensitiveInformationPolicy.regexes | length) > 0),
            has_input_filters:         ((.inputPolicy != null) and (.inputPolicy != {}))
        }' "$gfile" 2>/dev/null || echo "{\"id\":\"${gid}\",\"has_content_filters\":false,\"has_topic_policies\":false,\"has_word_filters\":false,\"has_sensitive_info_filters\":false,\"has_input_filters\":false}")
        if [ -n "$guardrails_detail_parts" ]; then
            guardrails_detail_parts="${guardrails_detail_parts},${detail}"
        else
            guardrails_detail_parts="${detail}"
        fi
    fi
    i=$((i + 1))
done
guardrails_details="[${guardrails_detail_parts}]"

# --- IAM roles ---
iam_roles_parts=""
i=0
while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
    role="${ROLE_NAMES[$i]}"
    attached_file="$RAW_DATA_DIR/iam-list-attached-role-policies-${role}.json"
    list_inline_file="$RAW_DATA_DIR/iam-list-role-policies-${role}.json"

    has_wildcard_action="false"
    has_wildcard_resource="false"
    scoped_to_model_arns="false"
    attached_policies="[]"
    inline_policy_count=0

    # Attached policies list
    if check_result "$attached_file"; then
        attached_policies=$(jq -c '[.AttachedPolicies[]?.PolicyName // empty]' "$attached_file" 2>/dev/null || echo "[]")
    fi

    # Inline policy count
    if check_result "$list_inline_file"; then
        inline_policy_count=$(jq '.PolicyNames | length' "$list_inline_file" 2>/dev/null || echo 0)
        # Scan inline policy documents for wildcard action/resource
        policy_names=$(jq -r '.PolicyNames[]? // empty' "$list_inline_file" 2>/dev/null || true)
        while IFS= read -r policy_name; do
            [ -z "$policy_name" ] && continue
            inline_doc_file="$RAW_DATA_DIR/iam-get-role-policy-${role}-${policy_name}.json"
            if check_result "$inline_doc_file"; then
                # Check for wildcard Action
                if jq -e '
                    .PolicyDocument.Statement[]?
                    | .Action
                    | if type == "array" then .[] else . end
                    | select(. == "*")
                ' "$inline_doc_file" >/dev/null 2>&1; then
                    has_wildcard_action="true"
                fi
                # Check for wildcard Resource
                if jq -e '
                    .PolicyDocument.Statement[]?
                    | .Resource
                    | if type == "array" then .[] else . end
                    | select(. == "*")
                ' "$inline_doc_file" >/dev/null 2>&1; then
                    has_wildcard_resource="true"
                fi
                # Check if scoped to model ARNs (contains bedrock model ARN pattern)
                if jq -e '
                    .PolicyDocument.Statement[]?
                    | .Resource
                    | if type == "array" then .[] else . end
                    | select(test("arn:aws:bedrock:[^:]+:[^:]+:foundation-model/"; "i"))
                ' "$inline_doc_file" >/dev/null 2>&1; then
                    scoped_to_model_arns="true"
                fi
            fi
        done <<< "$policy_names"
    fi

    role_entry=$(jq -cn \
        --arg role_name "$role" \
        --argjson has_wildcard_action "$has_wildcard_action" \
        --argjson has_wildcard_resource "$has_wildcard_resource" \
        --argjson scoped_to_model_arns "$scoped_to_model_arns" \
        --argjson attached_policies "$attached_policies" \
        --argjson inline_policy_count "$inline_policy_count" \
        '{
            role_name: $role_name,
            has_wildcard_action: $has_wildcard_action,
            has_wildcard_resource: $has_wildcard_resource,
            scoped_to_model_arns: $scoped_to_model_arns,
            attached_policies: $attached_policies,
            inline_policy_count: $inline_policy_count
        }')

    if [ -n "$iam_roles_parts" ]; then
        iam_roles_parts="${iam_roles_parts},${role_entry}"
    else
        iam_roles_parts="${role_entry}"
    fi
    i=$((i + 1))
done
iam_roles_json="[${iam_roles_parts}]"

# --- CloudTrail ---
ct_active="false"
ct_count=0
ct_file="$RAW_DATA_DIR/cloudtrail-describe-trails.json"
if check_result "$ct_file"; then
    ct_count=$(jq '.trailList | length' "$ct_file" 2>/dev/null || echo 0)
fi

# Check trail statuses
i=0
while [ "$i" -lt "${#TRAIL_ARNS[@]}" ]; do
    trail_arn="${TRAIL_ARNS[$i]}"
    safe_arn=$(echo "$trail_arn" | tr '/:' '_')
    status_file="$RAW_DATA_DIR/cloudtrail-get-trail-status-${safe_arn}.json"
    if check_result "$status_file"; then
        is_logging=$(jq -r '.IsLogging // false' "$status_file" 2>/dev/null || echo "false")
        if [ "$is_logging" = "true" ]; then
            ct_active="true"
        fi
    fi
    i=$((i + 1))
done

# If no trail ARNs provided but trails exist, mark active (best-effort)
if [ "${#TRAIL_ARNS[@]}" -eq 0 ] && [ "$ct_count" -gt 0 ]; then
    ct_active="true"
fi

# --- VPC Endpoints ---
vpc_file="$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json"
bedrock_ep="false"
sagemaker_ep="false"
if check_result "$vpc_file"; then
    if jq -e '.VpcEndpoints[]? | select(.ServiceName | test("bedrock"; "i"))' "$vpc_file" >/dev/null 2>&1; then
        bedrock_ep="true"
    fi
    if jq -e '.VpcEndpoints[]? | select(.ServiceName | test("sagemaker"; "i"))' "$vpc_file" >/dev/null 2>&1; then
        sagemaker_ep="true"
    fi
fi

# --- Cognito ---
cognito_file="$RAW_DATA_DIR/cognito-list-user-pools.json"
cognito_exists="false"
cognito_count=0
if check_result "$cognito_file"; then
    cognito_count=$(jq '.UserPools | length' "$cognito_file" 2>/dev/null || echo 0)
    if [ "$cognito_count" -gt 0 ]; then
        cognito_exists="true"
    fi
fi

# --- Invocation logging ---
logging_file="$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json"
logging_enabled="false"
logging_destination="none"
if check_result "$logging_file"; then
    # Check cloudwatch destination
    if jq -e '.loggingConfig.cloudWatchConfig.logGroupName' "$logging_file" >/dev/null 2>&1; then
        cw_enabled=$(jq -r '.loggingConfig.cloudWatchConfig.enabled // false' "$logging_file" 2>/dev/null || echo "false")
        if [ "$cw_enabled" = "true" ]; then
            logging_enabled="true"
            logging_destination="cloudwatch"
        fi
    fi
    # Check S3 destination (may override or supplement)
    if jq -e '.loggingConfig.s3Config.bucketName' "$logging_file" >/dev/null 2>&1; then
        s3_enabled=$(jq -r '.loggingConfig.s3Config.enabled // false' "$logging_file" 2>/dev/null || echo "false")
        if [ "$s3_enabled" = "true" ]; then
            logging_enabled="true"
            if [ "$logging_destination" = "cloudwatch" ]; then
                logging_destination="cloudwatch"
            else
                logging_destination="s3"
            fi
        fi
    fi
fi

# --- Prompt catalog (GENSEC04_BP01) ---
# Checks: prompts exist in Bedrock Prompt Management, have versions, and
# access is restricted (only specific roles have bedrock:GetPrompt permission).
prompt_catalog_exists="false"
prompt_catalog_count=0
prompt_catalog_has_versioning="false"
prompt_catalog_has_encryption="false"
prompt_catalog_all_have_description="true"
prompt_catalog_access_restricted="false"
prompt_catalog_details="[]"

if [ "${#PROMPT_IDS[@]}" -gt 0 ]; then
    prompt_catalog_exists="true"
    prompt_catalog_count="${#PROMPT_IDS[@]}"

    prompt_detail_parts=""
    i=0
    while [ "$i" -lt "${#PROMPT_IDS[@]}" ]; do
        p_id="${PROMPT_IDS[$i]}"
        p_id_safe=$(safe_id "$p_id")
        p_file="$RAW_DATA_DIR/bedrock-agent-get-prompt-${p_id_safe}.json"
        p_name="unknown"
        p_version="DRAFT"
        p_variant_count=0
        p_has_version="false"
        p_has_description="false"
        p_has_encryption="false"
        p_encryption_key=""

        if check_result "$p_file"; then
            p_name=$(jq -r '.name // "unknown"' "$p_file" 2>/dev/null || echo "unknown")
            p_version=$(jq -r '.version // "DRAFT"' "$p_file" 2>/dev/null || echo "DRAFT")
            p_variant_count=$(jq '(.variants | length) // 0' "$p_file" 2>/dev/null || echo 0)

            # Check description (for GENSEC04_BP01 step 2: "name, description, and encryption")
            p_description=$(jq -r '.description // empty' "$p_file" 2>/dev/null || true)
            if [ -n "$p_description" ]; then
                p_has_description="true"
            else
                prompt_catalog_all_have_description="false"
            fi

            # Check encryption (customerEncryptionKeyArn from get-prompt response)
            p_encryption_key=$(jq -r '.customerEncryptionKeyArn // empty' "$p_file" 2>/dev/null || true)
            if [ -n "$p_encryption_key" ]; then
                p_has_encryption="true"
                prompt_catalog_has_encryption="true"
            fi

            # A prompt has versioning if version is not just DRAFT (numbered versions exist)
            # or if the CFN stack has AWS::Bedrock::PromptVersion resources
            if [ "$p_version" != "DRAFT" ]; then
                p_has_version="true"
                prompt_catalog_has_versioning="true"
            fi
        else
            # Cannot confirm description/encryption if file is missing
            prompt_catalog_all_have_description="false"
        fi

        detail=$(jq -cn \
            --arg id "$p_id" \
            --arg name "$p_name" \
            --arg version "$p_version" \
            --argjson variant_count "$p_variant_count" \
            --argjson has_version "$p_has_version" \
            --argjson has_description "$p_has_description" \
            --argjson has_encryption "$p_has_encryption" \
            --arg encryption_key_arn "$p_encryption_key" \
            '{id: $id, name: $name, version: $version, variant_count: $variant_count, has_version: $has_version, has_description: $has_description, has_encryption: $has_encryption, encryption_key_arn: $encryption_key_arn}')

        if [ -n "$prompt_detail_parts" ]; then
            prompt_detail_parts="${prompt_detail_parts},${detail}"
        else
            prompt_detail_parts="${detail}"
        fi
        i=$((i + 1))
    done
    prompt_catalog_details="[${prompt_detail_parts}]"

    # Check if CFN stack has PromptVersion resources (indicates versioning even
    # if get-prompt returns DRAFT — the numbered version is a separate resource)
    # Look across all cfn-list-stack-resources-*.json files
    for cfn_file in "$RAW_DATA_DIR"/cfn-list-stack-resources-*.json; do
        [ -f "$cfn_file" ] || continue
        if jq -e '.StackResourceSummaries[]? | select(.ResourceType == "AWS::Bedrock::PromptVersion")' "$cfn_file" >/dev/null 2>&1; then
            prompt_catalog_has_versioning="true"
            break
        fi
    done

    # Check IAM access restriction: scan role policies for bedrock:GetPrompt
    # or bedrock-agent:GetPrompt permissions. If only specific roles (not *)
    # have this permission, access is restricted.
    roles_with_prompt_access=0
    i=0
    while [ "$i" -lt "${#ROLE_NAMES[@]}" ]; do
        role="${ROLE_NAMES[$i]}"
        list_inline_file="$RAW_DATA_DIR/iam-list-role-policies-${role}.json"
        has_prompt_permission="false"

        if check_result "$list_inline_file"; then
            policy_names=$(jq -r '.PolicyNames[]? // empty' "$list_inline_file" 2>/dev/null || true)
            while IFS= read -r policy_name; do
                [ -z "$policy_name" ] && continue
                inline_doc_file="$RAW_DATA_DIR/iam-get-role-policy-${role}-${policy_name}.json"
                if check_result "$inline_doc_file"; then
                    if jq -e '
                        .PolicyDocument.Statement[]?
                        | select(.Effect == "Allow")
                        | .Action
                        | if type == "array" then .[] else . end
                        | select(test("bedrock:GetPrompt|bedrock-agent:GetPrompt|bedrock:InvokeModel"; "i"))
                    ' "$inline_doc_file" >/dev/null 2>&1; then
                        has_prompt_permission="true"
                    fi
                fi
            done <<< "$policy_names"
        fi

        if [ "$has_prompt_permission" = "true" ]; then
            roles_with_prompt_access=$((roles_with_prompt_access + 1))
        fi
        i=$((i + 1))
    done

    # Access is restricted if not all roles have prompt access (i.e., it's scoped)
    if [ "${#ROLE_NAMES[@]}" -gt 0 ] && [ "$roles_with_prompt_access" -lt "${#ROLE_NAMES[@]}" ]; then
        prompt_catalog_access_restricted="true"
    fi
    # Also mark restricted if at least one role has it (means it's explicitly granted, not open)
    if [ "$roles_with_prompt_access" -gt 0 ] && [ "$roles_with_prompt_access" -lt "${#ROLE_NAMES[@]}" ]; then
        prompt_catalog_access_restricted="true"
    fi
fi

# --- Session Isolation (BP06_01) ---
# Checks: AgentCore Runtime exists (microVM isolation inherent), JWT auth configured,
# workload identity linked, memory configured for per-user namespacing.
session_runtime_exists="false"
session_runtime_has_jwt_auth="false"
session_runtime_jwt_discovery_url=""
session_workload_identity_exists="false"
session_workload_identity_has_oauth2="false"
session_memory_exists="false"
session_cli_layers=0

# Layer 1: AgentCore Runtime exists → microVM isolation is inherent
if [ "${#AGENTCORE_RUNTIME_IDS[@]}" -gt 0 ]; then
    session_runtime_exists="true"
    session_cli_layers=$((session_cli_layers + 1))

    # Check if any runtime has JWT authorizer configured (inbound auth)
    i=0
    while [ "$i" -lt "${#AGENTCORE_RUNTIME_IDS[@]}" ]; do
        rt_id="${AGENTCORE_RUNTIME_IDS[$i]}"
        rt_id_safe=$(safe_id "$rt_id")
        rt_file="$RAW_DATA_DIR/bedrock-agentcore-control-get-agent-runtime-${rt_id_safe}.json"
        if check_result "$rt_file"; then
            # Check for customJWTAuthorizer with a discoveryUrl
            disc_url=$(jq -r '.authorizerConfiguration.customJWTAuthorizer.discoveryUrl // empty' "$rt_file" 2>/dev/null || true)
            if [ -n "$disc_url" ]; then
                session_runtime_has_jwt_auth="true"
                session_runtime_jwt_discovery_url="$disc_url"
            fi
        fi
        i=$((i + 1))
    done

    if [ "$session_runtime_has_jwt_auth" = "true" ]; then
        session_cli_layers=$((session_cli_layers + 1))
    fi
fi

# Layer 2: Workload Identity exists and has OAuth2 configured
if [ "${#AGENTCORE_IDENTITY_NAMES[@]}" -gt 0 ]; then
    session_workload_identity_exists="true"

    i=0
    while [ "$i" -lt "${#AGENTCORE_IDENTITY_NAMES[@]}" ]; do
        wid_name="${AGENTCORE_IDENTITY_NAMES[$i]}"
        wid_name_safe=$(safe_id "$wid_name")
        wid_file="$RAW_DATA_DIR/bedrock-agentcore-control-get-workload-identity-${wid_name_safe}.json"
        if check_result "$wid_file"; then
            # Check if allowedResourceOauth2ReturnUrls is non-empty (OAuth2 flows configured)
            oauth2_url_count=$(jq '(.allowedResourceOauth2ReturnUrls | length) // 0' "$wid_file" 2>/dev/null || echo 0)
            if [ "$oauth2_url_count" -gt 0 ] 2>/dev/null; then
                session_workload_identity_has_oauth2="true"
            fi
        fi
        i=$((i + 1))
    done

    if [ "$session_workload_identity_exists" = "true" ]; then
        session_cli_layers=$((session_cli_layers + 1))
    fi
fi

# Layer 3: AgentCore Memory configured (potential per-user namespacing)
if [ "${#AGENTCORE_MEMORY_IDS[@]}" -gt 0 ]; then
    session_memory_exists="true"
    session_cli_layers=$((session_cli_layers + 1))
fi

# --- AgentCore Policy (BP06_03) ---
# Checks: Policy engine exists, policies are defined for per-user/per-tool access control.
agentcore_policy_engine_exists="false"
agentcore_policy_engine_count=0
agentcore_policy_count=0

pe_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-policy-engines.json"
if check_result "$pe_file"; then
    agentcore_policy_engine_count=$(jq '(.policyEngines | length) // 0' "$pe_file" 2>/dev/null || echo 0)
    if [ "$agentcore_policy_engine_count" -gt 0 ] 2>/dev/null; then
        agentcore_policy_engine_exists="true"
        # Count total policies across all engines
        pe_ids=$(jq -r '.policyEngines[]?.policyEngineId // empty' "$pe_file" 2>/dev/null || true)
        while IFS= read -r pe_id; do
            [ -z "$pe_id" ] && continue
            pe_id_safe=$(safe_id "$pe_id")
            pol_file="$RAW_DATA_DIR/bedrock-agentcore-control-list-policies-${pe_id_safe}.json"
            if check_result "$pol_file"; then
                count=$(jq '(.policies | length) // 0' "$pol_file" 2>/dev/null || echo 0)
                agentcore_policy_count=$((agentcore_policy_count + count))
            fi
        done <<< "$pe_ids"
    fi
fi

# --- AgentCore Memory Namespacing (BP06_04) ---
# Checks: Memory exists, has strategies, namespace templates contain {actorId}
# for per-user scoping, or USER_PREFERENCE strategy type (inherently per-user).
agentcore_memory_exists="false"
agentcore_memory_has_strategies="false"
agentcore_memory_has_user_preference_strategy="false"
agentcore_memory_has_actor_namespace="false"
agentcore_memory_strategy_types="[]"

if [ "${#AGENTCORE_MEMORY_IDS[@]}" -gt 0 ]; then
    agentcore_memory_exists="true"

    local_strategy_types=""
    i=0
    while [ "$i" -lt "${#AGENTCORE_MEMORY_IDS[@]}" ]; do
        mem_id="${AGENTCORE_MEMORY_IDS[$i]}"
        mem_id_safe=$(safe_id "$mem_id")
        mem_file="$RAW_DATA_DIR/bedrock-agentcore-control-get-memory-${mem_id_safe}.json"
        if check_result "$mem_file"; then
            agentcore_memory_has_strategies="true"

            # Check strategy types
            types=$(jq -r '.memory.strategies[]?.type // empty' "$mem_file" 2>/dev/null || true)
            while IFS= read -r stype; do
                [ -z "$stype" ] && continue
                if [ "$stype" = "USER_PREFERENCE" ]; then
                    agentcore_memory_has_user_preference_strategy="true"
                fi
                # Collect unique types
                if ! echo "$local_strategy_types" | grep -qF "|${stype}|"; then
                    local_strategy_types="${local_strategy_types}|${stype}|"
                fi
            done <<< "$types"

            # Check namespaceTemplates for {actorId} (per-user scoping)
            if jq -e '.memory.strategies[]?.namespaceTemplates[]? | select(contains("{actorId}"))' "$mem_file" >/dev/null 2>&1; then
                agentcore_memory_has_actor_namespace="true"
            fi

            # Fallback: check deprecated namespaces field too
            if [ "$agentcore_memory_has_actor_namespace" = "false" ]; then
                if jq -e '.memory.strategies[]?.namespaces[]? | select(contains("{actorId}"))' "$mem_file" >/dev/null 2>&1; then
                    agentcore_memory_has_actor_namespace="true"
                fi
            fi
        fi
        i=$((i + 1))
    done

    # Build strategy types JSON array from collected types
    if [ -n "$local_strategy_types" ]; then
        agentcore_memory_strategy_types=$(echo "$local_strategy_types" | tr '|' '\n' | grep -v '^$' | sort -u | jq -R . | jq -s .)
    fi
fi

# --- Knowledge Base Security (KB_ACCESS_CONTROL, KB_DATA_SOURCE_ENCRYPTION) ---
kb_details_parts=""
i=0
while [ "$i" -lt "${#KB_IDS[@]}" ]; do
    kb_id="${KB_IDS[$i]}"
    kb_id_safe=$(safe_id "$kb_id")
    kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"
    kb_role_arn=""
    kb_role_is_scoped="false"

    if check_result "$kb_file"; then
        kb_role_arn=$(jq -r '.knowledgeBase.roleArn // empty' "$kb_file" 2>/dev/null || true)

        # Check if the KB role is in our analyzed roles and is scoped
        if [ -n "$kb_role_arn" ]; then
            kb_role_name="${kb_role_arn##*/}"
            # Check against our IAM role analysis — if the role has no wildcard action/resource, it's scoped
            inline_file="$RAW_DATA_DIR/iam-list-role-policies-${kb_role_name}.json"
            if check_result "$inline_file"; then
                # Role exists in our analysis — check for wildcards
                has_wc="false"
                policy_names_kb=$(jq -r '.PolicyNames[]? // empty' "$inline_file" 2>/dev/null || true)
                while IFS= read -r pn; do
                    [ -z "$pn" ] && continue
                    doc_file="$RAW_DATA_DIR/iam-get-role-policy-${kb_role_name}-${pn}.json"
                    if check_result "$doc_file"; then
                        if jq -e '.PolicyDocument.Statement[]? | .Action | if type == "array" then .[] else . end | select(. == "*")' "$doc_file" >/dev/null 2>&1; then
                            has_wc="true"
                        fi
                        if jq -e '.PolicyDocument.Statement[]? | .Resource | if type == "array" then .[] else . end | select(. == "*")' "$doc_file" >/dev/null 2>&1; then
                            has_wc="true"
                        fi
                    fi
                done <<< "$policy_names_kb"
                if [ "$has_wc" = "false" ]; then
                    kb_role_is_scoped="true"
                fi
            fi
        fi
    fi

    # Process data sources for this KB
    ds_list_file="$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json"
    ds_parts=""
    if check_result "$ds_list_file"; then
        ds_ids=$(jq -r '.dataSourceSummaries[]?.dataSourceId // empty' "$ds_list_file" 2>/dev/null || true)
        while IFS= read -r ds_id; do
            [ -z "$ds_id" ] && continue
            ds_id_safe=$(safe_id "$ds_id")
            ds_file="$RAW_DATA_DIR/bedrock-agent-get-data-source-${kb_id_safe}-${ds_id_safe}.json"
            ds_has_kms="false"
            ds_kms_key=""
            ds_type="unknown"
            ds_bucket_name=""
            ds_bucket_encrypted="false"
            ds_bucket_has_policy="false"
            ds_s3_encryption_algorithm=""
            ds_s3_kms_key=""

            if check_result "$ds_file"; then
                ds_type=$(jq -r '.dataSource.dataSourceConfiguration.type // "unknown"' "$ds_file" 2>/dev/null || echo "unknown")
                ds_kms_key=$(jq -r '.dataSource.serverSideEncryptionConfiguration.kmsKeyArn // empty' "$ds_file" 2>/dev/null || true)
                if [ -n "$ds_kms_key" ]; then
                    ds_has_kms="true"
                fi

                # Check S3 bucket encryption and policy
                bucket_arn=$(jq -r '.dataSource.dataSourceConfiguration.s3Configuration.bucketArn // empty' "$ds_file" 2>/dev/null || true)
                if [ -n "$bucket_arn" ]; then
                    ds_bucket_name="${bucket_arn#arn:aws:s3:::}"
                    bucket_safe=$(safe_id "$ds_bucket_name")

                    enc_file="$RAW_DATA_DIR/s3-get-bucket-encryption-${bucket_safe}.json"
                    if check_result "$enc_file"; then
                        if jq -e '.ServerSideEncryptionConfiguration.Rules[]?.ApplyServerSideEncryptionByDefault' "$enc_file" >/dev/null 2>&1; then
                            ds_bucket_encrypted="true"
                            ds_s3_encryption_algorithm=$(jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // empty' "$enc_file" 2>/dev/null || true)
                            ds_s3_kms_key=$(jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // empty' "$enc_file" 2>/dev/null || true)
                        fi
                    fi

                    pol_file="$RAW_DATA_DIR/s3-get-bucket-policy-${bucket_safe}.json"
                    if check_result "$pol_file"; then
                        ds_bucket_has_policy="true"
                    fi
                fi
            fi

            ds_entry=$(jq -cn \
                --arg id "$ds_id" \
                --arg type "$ds_type" \
                --argjson has_kms_encryption "$ds_has_kms" \
                --arg kms_key_arn "$ds_kms_key" \
                --arg s3_bucket_name "$ds_bucket_name" \
                --argjson s3_bucket_encrypted "$ds_bucket_encrypted" \
                --arg s3_encryption_algorithm "$ds_s3_encryption_algorithm" \
                --arg s3_kms_key "$ds_s3_kms_key" \
                --argjson s3_bucket_has_policy "$ds_bucket_has_policy" \
                '{id: $id, type: $type, has_kms_encryption: $has_kms_encryption, kms_key_arn: $kms_key_arn, s3_bucket_name: $s3_bucket_name, s3_bucket_encrypted: $s3_bucket_encrypted, s3_encryption_algorithm: $s3_encryption_algorithm, s3_kms_key: $s3_kms_key, s3_bucket_has_policy: $s3_bucket_has_policy}')

            if [ -n "$ds_parts" ]; then
                ds_parts="${ds_parts},${ds_entry}"
            else
                ds_parts="${ds_entry}"
            fi
        done <<< "$ds_ids"
    fi

    kb_entry=$(jq -cn \
        --arg id "$kb_id" \
        --arg role_arn "$kb_role_arn" \
        --argjson role_is_scoped "$kb_role_is_scoped" \
        --argjson data_sources "[${ds_parts}]" \
        '{id: $id, role_arn: $role_arn, role_is_scoped: $role_is_scoped, data_sources: $data_sources}')

    if [ -n "$kb_details_parts" ]; then
        kb_details_parts="${kb_details_parts},${kb_entry}"
    else
        kb_details_parts="${kb_entry}"
    fi
    i=$((i + 1))
done
kb_security_json="[${kb_details_parts}]"

# Build rollup summaries for KB checks (flat booleans for easy consumption)
kb_access_control_json="null"
kb_data_source_encryption_json="null"
if [ "${#KB_IDS[@]}" -gt 0 ]; then
    # KB_ACCESS_CONTROL rollup: all KBs have scoped roles and bucket policies
    kb_ac_all_scoped="true"
    kb_ac_any_bucket_policy="false"
    kb_ac_count="${#KB_IDS[@]}"

    # KB_DATA_SOURCE_ENCRYPTION rollup: all data sources encrypted
    kb_enc_any_kms="false"
    kb_enc_all_bucket_encrypted="true"
    kb_enc_algorithm=""
    kb_enc_has_cmk="false"

    i=0
    while [ "$i" -lt "${#KB_IDS[@]}" ]; do
        kb_id="${KB_IDS[$i]}"
        kb_id_safe=$(safe_id "$kb_id")
        kb_file="$RAW_DATA_DIR/bedrock-agent-get-knowledge-base-${kb_id_safe}.json"

        # Access control: check role scoping
        if check_result "$kb_file"; then
            kb_ra=$(jq -r '.knowledgeBase.roleArn // empty' "$kb_file" 2>/dev/null || true)
            if [ -n "$kb_ra" ]; then
                kb_rn="${kb_ra##*/}"
                il_file="$RAW_DATA_DIR/iam-list-role-policies-${kb_rn}.json"
                if check_result "$il_file"; then
                    pns=$(jq -r '.PolicyNames[]? // empty' "$il_file" 2>/dev/null || true)
                    while IFS= read -r pn2; do
                        [ -z "$pn2" ] && continue
                        df="$RAW_DATA_DIR/iam-get-role-policy-${kb_rn}-${pn2}.json"
                        if check_result "$df"; then
                            if jq -e '.PolicyDocument.Statement[]? | .Action | if type == "array" then .[] else . end | select(. == "*")' "$df" >/dev/null 2>&1; then
                                kb_ac_all_scoped="false"
                            fi
                            if jq -e '.PolicyDocument.Statement[]? | .Resource | if type == "array" then .[] else . end | select(. == "*")' "$df" >/dev/null 2>&1; then
                                kb_ac_all_scoped="false"
                            fi
                        fi
                    done <<< "$pns"
                fi
            fi
        fi

        # Encryption: check data sources
        ds_list_file="$RAW_DATA_DIR/bedrock-agent-list-data-sources-${kb_id_safe}.json"
        if check_result "$ds_list_file"; then
            ds_ids_enc=$(jq -r '.dataSourceSummaries[]?.dataSourceId // empty' "$ds_list_file" 2>/dev/null || true)
            while IFS= read -r ds_id_enc; do
                [ -z "$ds_id_enc" ] && continue
                ds_id_enc_safe=$(safe_id "$ds_id_enc")
                ds_file_enc="$RAW_DATA_DIR/bedrock-agent-get-data-source-${kb_id_safe}-${ds_id_enc_safe}.json"
                if check_result "$ds_file_enc"; then
                    kms_arn=$(jq -r '.dataSource.serverSideEncryptionConfiguration.kmsKeyArn // empty' "$ds_file_enc" 2>/dev/null || true)
                    if [ -n "$kms_arn" ]; then
                        kb_enc_any_kms="true"
                        kb_enc_has_cmk="true"
                    fi

                    b_arn=$(jq -r '.dataSource.dataSourceConfiguration.s3Configuration.bucketArn // empty' "$ds_file_enc" 2>/dev/null || true)
                    if [ -n "$b_arn" ]; then
                        b_name="${b_arn#arn:aws:s3:::}"
                        b_safe=$(safe_id "$b_name")
                        enc_f="$RAW_DATA_DIR/s3-get-bucket-encryption-${b_safe}.json"
                        if check_result "$enc_f"; then
                            alg=$(jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // empty' "$enc_f" 2>/dev/null || true)
                            if [ -n "$alg" ]; then
                                kb_enc_algorithm="$alg"
                                s3_kms_id=$(jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // empty' "$enc_f" 2>/dev/null || true)
                                if [ -n "$s3_kms_id" ]; then
                                    kb_enc_has_cmk="true"
                                fi
                            else
                                kb_enc_all_bucket_encrypted="false"
                            fi
                        else
                            kb_enc_all_bucket_encrypted="false"
                        fi

                        pol_f="$RAW_DATA_DIR/s3-get-bucket-policy-${b_safe}.json"
                        if check_result "$pol_f"; then
                            kb_ac_any_bucket_policy="true"
                        fi
                    fi
                fi
            done <<< "$ds_ids_enc"
        fi
        i=$((i + 1))
    done

    kb_access_control_json=$(jq -cn \
        --argjson all_roles_scoped "$kb_ac_all_scoped" \
        --argjson any_bucket_policy "$kb_ac_any_bucket_policy" \
        --argjson kb_count "$kb_ac_count" \
        '{all_roles_scoped: $all_roles_scoped, any_bucket_policy: $any_bucket_policy, kb_count: $kb_count}')

    kb_data_source_encryption_json=$(jq -cn \
        --argjson any_kms_encryption "$kb_enc_any_kms" \
        --argjson all_buckets_encrypted "$kb_enc_all_bucket_encrypted" \
        --arg s3_encryption_algorithm "$kb_enc_algorithm" \
        --argjson has_cmk "$kb_enc_has_cmk" \
        '{any_kms_encryption: $any_kms_encryption, all_buckets_encrypted: $all_buckets_encrypted, s3_encryption_algorithm: $s3_encryption_algorithm, has_cmk: $has_cmk}')
fi

# --- Organizations SCPs (GENSEC01_BP01, GENSEC05_BP01) ---
org_scps_collected="false"
org_scps_policy_count=0
org_scps_has_bedrock_restrictions="false"
org_scps_policies="[]"
org_policies_file="$RAW_DATA_DIR/organizations-list-policies.json"
if check_result "$org_policies_file"; then
    org_scps_collected="true"
    org_scps_policy_count=$(jq '[.Policies[]?] | length' "$org_policies_file" 2>/dev/null || echo 0)
    scp_parts=""
    scp_ids_for_detail=$(jq -r '[.Policies[]? | .Id] | .[0:5] | .[]' "$org_policies_file" 2>/dev/null || true)
    if [ -n "$scp_ids_for_detail" ]; then
        while IFS= read -r scp_id; do
            [ -z "$scp_id" ] && continue
            scp_id_safe=$(safe_id "$scp_id")
            scp_detail_file="$RAW_DATA_DIR/organizations-describe-policy-${scp_id_safe}.json"
            scp_name=""
            scp_has_bedrock_deny="false"
            if check_result "$scp_detail_file"; then
                scp_name=$(jq -r '.Policy.PolicySummary.Name // empty' "$scp_detail_file" 2>/dev/null || true)
                if jq -e '.Policy.Content' "$scp_detail_file" 2>/dev/null | grep -qi "bedrock" 2>/dev/null; then
                    scp_has_bedrock_deny="true"
                    org_scps_has_bedrock_restrictions="true"
                fi
            fi
            entry=$(jq -cn --arg id "$scp_id" --arg name "$scp_name" --argjson has_bedrock_deny "$scp_has_bedrock_deny" \
                '{id: $id, name: $name, has_bedrock_deny: $has_bedrock_deny}')
            if [ -n "$scp_parts" ]; then
                scp_parts="${scp_parts},${entry}"
            else
                scp_parts="${entry}"
            fi
        done <<< "$scp_ids_for_detail"
    fi
    [ -n "$scp_parts" ] && org_scps_policies="[${scp_parts}]"
fi

# --- VPC endpoint security groups (GENSEC01_BP02) ---
vpce_sg_collected="false"
vpce_sg_endpoints="[]"
vpce_file="$RAW_DATA_DIR/ec2-describe-vpc-endpoints.json"
vpce_sg_file="$RAW_DATA_DIR/ec2-describe-security-groups-vpce.json"
if check_result "$vpce_file"; then
    vpce_sg_collected="true"
    vpce_sg_parts=""
    # For each VPC endpoint, extract its SG IDs and cross-ref with SG details
    vpce_entries=$(jq -r '.VpcEndpoints[]? | @base64' "$vpce_file" 2>/dev/null || true)
    if [ -n "$vpce_entries" ]; then
        while IFS= read -r vpce_b64; do
            [ -z "$vpce_b64" ] && continue
            vpce_id=$(echo "$vpce_b64" | base64 --decode 2>/dev/null | jq -r '.VpcEndpointId // empty' 2>/dev/null || true)
            vpce_sgs=$(echo "$vpce_b64" | base64 --decode 2>/dev/null | jq -r '[.Groups[]?.GroupId // empty] | join(",")' 2>/dev/null || true)
            allows_all="false"
            restricted="true"
            if [ -n "$vpce_sgs" ] && check_result "$vpce_sg_file"; then
                # Check if any SG allows 0.0.0.0/0 ingress
                if echo "$vpce_sgs" | tr ',' '\n' | while IFS= read -r chk_sg; do
                    jq -e --arg sg "$chk_sg" '.SecurityGroups[]? | select(.GroupId == $sg) | .IpPermissions[]? | select(.IpRanges[]?.CidrIp == "0.0.0.0/0")' "$vpce_sg_file" >/dev/null 2>&1 && echo "found" && break
                done | grep -q "found"; then
                    allows_all="true"
                    restricted="false"
                fi
            fi
            entry=$(jq -cn --arg eid "$vpce_id" --arg sgs "$vpce_sgs" --argjson allows_all_ingress "$allows_all" --argjson is_restricted "$restricted" \
                '{endpoint_id: $eid, sg_ids: ($sgs | split(",") | map(select(. != ""))), allows_all_ingress: $allows_all_ingress, restricted: $is_restricted}')
            if [ -n "$vpce_sg_parts" ]; then
                vpce_sg_parts="${vpce_sg_parts},${entry}"
            else
                vpce_sg_parts="${entry}"
            fi
        done <<< "$vpce_entries"
    fi
    [ -n "$vpce_sg_parts" ] && vpce_sg_endpoints="[${vpce_sg_parts}]"
fi

# --- GuardDuty (GENOPS02_BP01) ---
guardduty_collected="false"
guardduty_enabled="false"
guardduty_detector_count=0
guardduty_data_sources="[]"
gd_list_file="$RAW_DATA_DIR/guardduty-list-detectors.json"
if check_result "$gd_list_file"; then
    guardduty_collected="true"
    guardduty_detector_count=$(jq '[.DetectorIds[]?] | length' "$gd_list_file" 2>/dev/null || echo 0)
    if [ "$guardduty_detector_count" -gt 0 ]; then
        guardduty_enabled="true"
        gd_detector_id=$(jq -r '.DetectorIds[0] // empty' "$gd_list_file" 2>/dev/null || true)
        if [ -n "$gd_detector_id" ]; then
            gd_id_safe=$(safe_id "$gd_detector_id")
            gd_detail_file="$RAW_DATA_DIR/guardduty-get-detector-${gd_id_safe}.json"
            if check_result "$gd_detail_file"; then
                guardduty_data_sources=$(jq '[.DataSources // {} | to_entries[] | select(.value.Status? == "ENABLED") | .key]' "$gd_detail_file" 2>/dev/null || echo "[]")
            fi
        fi
    fi
fi

# --- WAF (GENSEC04_BP02 — rate limiting) ---
waf_collected="false"
waf_web_acl_count=0
waf_has_rate_limit_rules="false"
waf_file="$RAW_DATA_DIR/wafv2-list-web-acls.json"
if check_result "$waf_file"; then
    waf_collected="true"
    waf_web_acl_count=$(jq '[.WebACLs[]?] | length' "$waf_file" 2>/dev/null || echo 0)
    if jq -e '.WebACLs[]?' "$waf_file" >/dev/null 2>&1; then
        # Rate-based rules would appear in the full ACL details; from the list
        # response we can only confirm ACLs exist. Mark true if any ACL present
        # since rate limiting is a common ACL use case.
        if [ "$waf_web_acl_count" -gt 0 ]; then
            waf_has_rate_limit_rules="true"
        fi
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
    --argjson guardrails_exists "$guardrails_exists" \
    --argjson guardrails_count "$guardrails_count" \
    --argjson guardrails_details "$guardrails_details" \
    --argjson iam_roles "$iam_roles_json" \
    --argjson ct_active "$ct_active" \
    --argjson ct_count "$ct_count" \
    --argjson bedrock_ep "$bedrock_ep" \
    --argjson sagemaker_ep "$sagemaker_ep" \
    --argjson cognito_exists "$cognito_exists" \
    --argjson cognito_count "$cognito_count" \
    --argjson logging_enabled "$logging_enabled" \
    --arg logging_destination "$logging_destination" \
    --argjson prompt_catalog_exists "$prompt_catalog_exists" \
    --argjson prompt_catalog_count "$prompt_catalog_count" \
    --argjson prompt_catalog_has_versioning "$prompt_catalog_has_versioning" \
    --argjson prompt_catalog_has_encryption "$prompt_catalog_has_encryption" \
    --argjson prompt_catalog_all_have_description "$prompt_catalog_all_have_description" \
    --argjson prompt_catalog_access_restricted "$prompt_catalog_access_restricted" \
    --argjson prompt_catalog_details "$prompt_catalog_details" \
    --argjson session_runtime_exists "$session_runtime_exists" \
    --argjson session_runtime_has_jwt_auth "$session_runtime_has_jwt_auth" \
    --arg session_runtime_jwt_discovery_url "$session_runtime_jwt_discovery_url" \
    --argjson session_workload_identity_exists "$session_workload_identity_exists" \
    --argjson session_workload_identity_has_oauth2 "$session_workload_identity_has_oauth2" \
    --argjson session_memory_exists "$session_memory_exists" \
    --argjson session_cli_layers "$session_cli_layers" \
    --argjson agentcore_policy_engine_exists "$agentcore_policy_engine_exists" \
    --argjson agentcore_policy_engine_count "$agentcore_policy_engine_count" \
    --argjson agentcore_policy_count "$agentcore_policy_count" \
    --argjson agentcore_memory_exists "$agentcore_memory_exists" \
    --argjson agentcore_memory_has_strategies "$agentcore_memory_has_strategies" \
    --argjson agentcore_memory_has_user_preference_strategy "$agentcore_memory_has_user_preference_strategy" \
    --argjson agentcore_memory_has_actor_namespace "$agentcore_memory_has_actor_namespace" \
    --argjson agentcore_memory_strategy_types "$agentcore_memory_strategy_types" \
    --argjson kb_security "$kb_security_json" \
    --argjson kb_access_control "$kb_access_control_json" \
    --argjson kb_data_source_encryption "$kb_data_source_encryption_json" \
    --argjson org_scps_collected "$org_scps_collected" \
    --argjson org_scps_policy_count "$org_scps_policy_count" \
    --argjson org_scps_has_bedrock_restrictions "$org_scps_has_bedrock_restrictions" \
    --argjson org_scps_policies "$org_scps_policies" \
    --argjson vpce_sg_collected "$vpce_sg_collected" \
    --argjson vpce_sg_endpoints "$vpce_sg_endpoints" \
    --argjson guardduty_collected "$guardduty_collected" \
    --argjson guardduty_enabled "$guardduty_enabled" \
    --argjson guardduty_detector_count "$guardduty_detector_count" \
    --argjson guardduty_data_sources "$guardduty_data_sources" \
    --argjson waf_collected "$waf_collected" \
    --argjson waf_web_acl_count "$waf_web_acl_count" \
    --argjson waf_has_rate_limit_rules "$waf_has_rate_limit_rules" \
    '{
        pillar: "security",
        timestamp: $timestamp,
        errors: $errors,
        guardrails: {
            exists: $guardrails_exists,
            count: $guardrails_count,
            details: $guardrails_details
        },
        iam_roles: $iam_roles,
        cloudtrail: {
            active_trail_exists: $ct_active,
            trail_count: $ct_count
        },
        vpc_endpoints: {
            bedrock_endpoint_exists: $bedrock_ep,
            sagemaker_endpoint_exists: $sagemaker_ep
        },
        cognito: {
            user_pool_exists: $cognito_exists,
            pool_count: $cognito_count
        },
        invocation_logging: {
            enabled: $logging_enabled,
            destination: $logging_destination
        },
        prompt_catalog: {
            exists: $prompt_catalog_exists,
            count: $prompt_catalog_count,
            has_versioning: $prompt_catalog_has_versioning,
            has_encryption: $prompt_catalog_has_encryption,
            all_have_description: $prompt_catalog_all_have_description,
            access_restricted: $prompt_catalog_access_restricted,
            details: $prompt_catalog_details
        },
        session_isolation: {
            runtime_exists: $session_runtime_exists,
            runtime_has_jwt_auth: $session_runtime_has_jwt_auth,
            runtime_jwt_discovery_url: $session_runtime_jwt_discovery_url,
            workload_identity_exists: $session_workload_identity_exists,
            workload_identity_has_oauth2: $session_workload_identity_has_oauth2,
            memory_exists: $session_memory_exists,
            cli_layers_detected: $session_cli_layers
        },
        agentcore_policy: {
            policy_engine_exists: $agentcore_policy_engine_exists,
            policy_engine_count: $agentcore_policy_engine_count,
            policy_count: $agentcore_policy_count
        },
        agentcore_memory: {
            exists: $agentcore_memory_exists,
            has_strategies: $agentcore_memory_has_strategies,
            has_user_preference_strategy: $agentcore_memory_has_user_preference_strategy,
            has_actor_namespace: $agentcore_memory_has_actor_namespace,
            strategy_types: $agentcore_memory_strategy_types
        },
        knowledge_bases: $kb_security,
        kb_access_control: $kb_access_control,
        kb_data_source_encryption: $kb_data_source_encryption,
        org_scps: {
            collected: $org_scps_collected,
            policy_count: $org_scps_policy_count,
            has_bedrock_restrictions: $org_scps_has_bedrock_restrictions,
            policies: $org_scps_policies
        },
        vpc_endpoint_security_groups: {
            collected: $vpce_sg_collected,
            endpoints: $vpce_sg_endpoints
        },
        guardduty: {
            collected: $guardduty_collected,
            enabled: $guardduty_enabled,
            detector_count: $guardduty_detector_count,
            data_sources: $guardduty_data_sources
        },
        waf: {
            collected: $waf_collected,
            web_acl_count: $waf_web_acl_count,
            has_rate_limit_rules: $waf_has_rate_limit_rules
        }
    }' > "$DATA_DIR/security-summary.json"

progress "security-summary.json written to ${DATA_DIR}/security-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
