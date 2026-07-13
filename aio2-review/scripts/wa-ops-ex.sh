#!/usr/bin/env bash
# wa-ops-ex.sh — WA Operational Excellence pillar data collection for AIO2 review
#
# Usage:
#   wa-ops-ex.sh --region <region> --data-dir <path> [--profile <profile>]
#     [--agent-id <id>] [--lambda-names <name1,name2,...>]
#
# Writes: $DATA_DIR/ops-ex-summary.json
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

LAMBDA_NAMES=()
if [ -n "$LAMBDA_NAMES_RAW" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] && LAMBDA_NAMES+=("$item")
    done < <(split_csv "$LAMBDA_NAMES_RAW")
fi

# ---------------------------------------------------------------------------
# Phase 1 — parallel fetches
# ---------------------------------------------------------------------------
progress "Phase 1: Fetching operational excellence data..."

# Agent fetch (only if AGENT_ID is set)
if [ -n "$AGENT_ID" ]; then
    fetch_or_cache "$RAW_DATA_DIR/bedrock-agent-get-agent.json" \
        aws bedrock-agent get-agent --agent-id "$AGENT_ID" \
            --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
fi

fetch_or_cache "$RAW_DATA_DIR/cloudwatch-list-dashboards.json" \
    aws cloudwatch list-dashboards --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/cloudwatch-describe-alarms.json" \
    aws cloudwatch describe-alarms --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/logs-describe-log-groups-bedrock.json" \
    aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock" \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/logs-describe-log-groups-lambda.json" \
    aws logs describe-log-groups --log-group-name-prefix "/aws/lambda" \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json" \
    aws bedrock get-model-invocation-logging-configuration \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Evaluation jobs (GENOPS01_BP01 — periodic evaluation)
fetch_or_cache "$RAW_DATA_DIR/bedrock-list-evaluation-jobs.json" \
    aws bedrock list-evaluation-jobs \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# Service quota change history (GENOPS02_BP03 — quota management)
fetch_or_cache "$RAW_DATA_DIR/service-quotas-bedrock-change-history.json" \
    aws service-quotas list-requested-service-quota-change-history \
        --service-code bedrock \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# X-Ray sampling rules (GENOPS03_BP02 — tracing)
fetch_or_cache "$RAW_DATA_DIR/xray-get-sampling-rules.json" \
    aws xray get-sampling-rules \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# CloudWatch namespace metrics (GENSEC03_BP01, GENOPS02_BP02)
fetch_or_cache "$RAW_DATA_DIR/cloudwatch-list-metrics-bedrock-agentcore.json" \
    aws cloudwatch list-metrics --namespace bedrock-agentcore \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/cloudwatch-list-metrics-aws-bedrock.json" \
    aws cloudwatch list-metrics --namespace AWS/Bedrock \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# EventBridge rules (GENOPS02_BP02, GENREL03_BP02)
fetch_or_cache "$RAW_DATA_DIR/events-list-rules.json" \
    aws events list-rules \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# SNS topics and subscriptions (GENOPS02_BP02 — alarm notification targets)
fetch_or_cache "$RAW_DATA_DIR/sns-list-topics.json" \
    aws sns list-topics \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

fetch_or_cache "$RAW_DATA_DIR/sns-list-subscriptions.json" \
    aws sns list-subscriptions \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

# AWS Config recorder (GENOPS04_BP01 — governance)
fetch_or_cache "$RAW_DATA_DIR/configservice-describe-configuration-recorders.json" \
    aws configservice describe-configuration-recorders \
        --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &

wait
progress "Phase 1 complete."

# ---------------------------------------------------------------------------
# Phase 2 — dependent fetches (need Phase 1 results)
# ---------------------------------------------------------------------------

# EventBridge: fetch targets for bedrock/agent-related rules (max 5)
events_file_p2="$RAW_DATA_DIR/events-list-rules.json"
if check_result "$events_file_p2"; then
    eb_rules_to_query=$(jq -r '[.Rules[]? | select(.Name | test("bedrock|agent|genai|ai"; "i")) | .Name] | .[0:5] | .[]' "$events_file_p2" 2>/dev/null || true)
    if [ -n "$eb_rules_to_query" ]; then
        while IFS= read -r rule_name; do
            [ -z "$rule_name" ] && continue
            rule_safe=$(echo "$rule_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
            fetch_or_cache "$RAW_DATA_DIR/events-list-targets-${rule_safe}.json" \
                aws events list-targets-by-rule --rule "$rule_name" \
                    --region "$REGION" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --output json &
        done <<< "$eb_rules_to_query"
        wait
    fi
fi

# ---------------------------------------------------------------------------
# Build ops-ex-summary.json
# ---------------------------------------------------------------------------
progress "Building ops-ex-summary.json..."

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Agent ---
agent_model_id="null"
agent_idle_ttl="null"
agent_file="$RAW_DATA_DIR/bedrock-agent-get-agent.json"
if [ -n "$AGENT_ID" ] && check_result "$agent_file"; then
    raw_model=$(jq -r '.agent.foundationModel // empty' "$agent_file" 2>/dev/null || true)
    raw_ttl=$(jq -r '.agent.idleSessionTTLInSeconds // empty' "$agent_file" 2>/dev/null || true)
    [ -n "$raw_model" ] && agent_model_id="\"${raw_model}\""
    [ -n "$raw_ttl" ]   && agent_idle_ttl="$raw_ttl"
fi

# --- Dashboards ---
dash_file="$RAW_DATA_DIR/cloudwatch-list-dashboards.json"
dash_count=0
has_bedrock_dashboard="false"
if check_result "$dash_file"; then
    dash_count=$(jq '.DashboardEntries | length' "$dash_file" 2>/dev/null || echo 0)
    if jq -e '.DashboardEntries[]? | select(.DashboardName | test("bedrock"; "i"))' "$dash_file" >/dev/null 2>&1; then
        has_bedrock_dashboard="true"
    fi
fi

# --- Alarms ---
alarms_file="$RAW_DATA_DIR/cloudwatch-describe-alarms.json"
alarms_count=0
bedrock_alarm_count=0
lambda_alarm_count=0
bedrock_alarm_metrics="[]"
if check_result "$alarms_file"; then
    alarms_count=$(jq '(.MetricAlarms | length) + (.CompositeAlarms | length)' "$alarms_file" 2>/dev/null || echo 0)
    bedrock_alarm_count=$(jq '[.MetricAlarms[]? | select(.Namespace | test("Bedrock"; "i"))] | length' "$alarms_file" 2>/dev/null || echo 0)
    lambda_alarm_count=$(jq '[.MetricAlarms[]? | select(.Namespace | test("Lambda"; "i"))] | length' "$alarms_file" 2>/dev/null || echo 0)
    bedrock_alarm_metrics=$(jq '[.MetricAlarms[]? | select(.Namespace | test("Bedrock"; "i")) | .MetricName] | unique' "$alarms_file" 2>/dev/null || echo "[]")
fi

# --- Log groups ---
bedrock_lg_file="$RAW_DATA_DIR/logs-describe-log-groups-bedrock.json"
lambda_lg_file="$RAW_DATA_DIR/logs-describe-log-groups-lambda.json"
bedrock_lg_count=0
lambda_lg_count=0
if check_result "$bedrock_lg_file"; then
    bedrock_lg_count=$(jq '.logGroups | length' "$bedrock_lg_file" 2>/dev/null || echo 0)
fi
if check_result "$lambda_lg_file"; then
    lambda_lg_count=$(jq '.logGroups | length' "$lambda_lg_file" 2>/dev/null || echo 0)
fi

# --- Invocation logging ---
logging_file="$RAW_DATA_DIR/bedrock-get-model-invocation-logging-configuration.json"
logging_enabled="false"
logging_destination="none"
if check_result "$logging_file"; then
    if jq -e '.loggingConfig.cloudWatchConfig.logGroupName' "$logging_file" >/dev/null 2>&1; then
        cw_enabled=$(jq -r '.loggingConfig.cloudWatchConfig.enabled // false' "$logging_file" 2>/dev/null || echo "false")
        if [ "$cw_enabled" = "true" ]; then
            logging_enabled="true"
            logging_destination="cloudwatch"
        fi
    fi
    if jq -e '.loggingConfig.s3Config.bucketName' "$logging_file" >/dev/null 2>&1; then
        s3_enabled=$(jq -r '.loggingConfig.s3Config.enabled // false' "$logging_file" 2>/dev/null || echo "false")
        if [ "$s3_enabled" = "true" ]; then
            logging_enabled="true"
            if [ "$logging_destination" = "none" ]; then
                logging_destination="s3"
            fi
        fi
    fi
fi

# --- Evaluation jobs (GENOPS01_BP01) ---
eval_file="$RAW_DATA_DIR/bedrock-list-evaluation-jobs.json"
eval_job_count=0
eval_latest_status="null"
eval_latest_date="null"
if check_result "$eval_file"; then
    eval_job_count=$(jq '[.jobSummaries[]?] | length' "$eval_file" 2>/dev/null || echo 0)
    local_status=$(jq -r '[.jobSummaries[]?] | sort_by(.creationTime) | last | .status // empty' "$eval_file" 2>/dev/null || true)
    local_date=$(jq -r '[.jobSummaries[]?] | sort_by(.creationTime) | last | .creationTime // empty' "$eval_file" 2>/dev/null || true)
    [ -n "$local_status" ] && eval_latest_status="\"${local_status}\""
    [ -n "$local_date" ] && eval_latest_date="\"${local_date}\""
fi

# --- Quota management (GENOPS02_BP03) ---
quota_file="$RAW_DATA_DIR/service-quotas-bedrock-change-history.json"
quota_change_count=0
has_quota_increases="false"
if check_result "$quota_file"; then
    quota_change_count=$(jq '[.RequestedQuotas[]?] | length' "$quota_file" 2>/dev/null || echo 0)
    if [ "$quota_change_count" -gt 0 ]; then
        has_quota_increases="true"
    fi
fi

# --- Custom models (GENOPS05_BP01) ---
custom_model_count=0
if [ -f "$DATA_DIR/manifest.json" ]; then
    custom_model_count=$(jq '(.custom_model_ids // []) | length' "$DATA_DIR/manifest.json" 2>/dev/null || echo 0)
fi

# --- X-Ray sampling rules (GENOPS03_BP02) ---
xray_file="$RAW_DATA_DIR/xray-get-sampling-rules.json"
xray_collected="false"
xray_sampling_rules_count=0
xray_has_custom_rules="false"
xray_default_rate="null"
if check_result "$xray_file"; then
    xray_collected="true"
    xray_sampling_rules_count=$(jq '[.SamplingRuleRecords[]?] | length' "$xray_file" 2>/dev/null || echo 0)
    if jq -e '.SamplingRuleRecords[]? | select(.SamplingRule.RuleName != "Default")' "$xray_file" >/dev/null 2>&1; then
        xray_has_custom_rules="true"
    fi
    raw_rate=$(jq -r '.SamplingRuleRecords[]? | select(.SamplingRule.RuleName == "Default") | .SamplingRule.FixedRate // empty' "$xray_file" 2>/dev/null || true)
    [ -n "$raw_rate" ] && xray_default_rate="$raw_rate"
fi

# --- CloudWatch namespace metrics (GENSEC03_BP01, GENOPS02_BP02) ---
cw_agentcore_file="$RAW_DATA_DIR/cloudwatch-list-metrics-bedrock-agentcore.json"
cw_bedrock_file="$RAW_DATA_DIR/cloudwatch-list-metrics-aws-bedrock.json"
cw_metrics_collected="false"
cw_bedrock_agentcore_count=0
cw_aws_bedrock_count=0
cw_has_token_metrics="false"
cw_has_latency_metrics="false"
if check_result "$cw_agentcore_file" || check_result "$cw_bedrock_file"; then
    cw_metrics_collected="true"
fi
if check_result "$cw_agentcore_file"; then
    cw_bedrock_agentcore_count=$(jq '[.Metrics[]?] | length' "$cw_agentcore_file" 2>/dev/null || echo 0)
fi
if check_result "$cw_bedrock_file"; then
    cw_aws_bedrock_count=$(jq '[.Metrics[]?] | length' "$cw_bedrock_file" 2>/dev/null || echo 0)
    if jq -e '.Metrics[]? | select(.MetricName | test("InputTokenCount|OutputTokenCount"; "i"))' "$cw_bedrock_file" >/dev/null 2>&1; then
        cw_has_token_metrics="true"
    fi
    if jq -e '.Metrics[]? | select(.MetricName | test("Latency|Duration"; "i"))' "$cw_bedrock_file" >/dev/null 2>&1; then
        cw_has_latency_metrics="true"
    fi
fi

# --- EventBridge (GENOPS02_BP02, GENREL03_BP02) ---
eb_file="$RAW_DATA_DIR/events-list-rules.json"
eb_collected="false"
eb_rule_count=0
eb_has_bedrock_rules="false"
eb_has_agent_rules="false"
eb_rules_with_targets="[]"
if check_result "$eb_file"; then
    eb_collected="true"
    eb_rule_count=$(jq '[.Rules[]?] | length' "$eb_file" 2>/dev/null || echo 0)
    if jq -e '.Rules[]? | select(.Name | test("bedrock"; "i"))' "$eb_file" >/dev/null 2>&1; then
        eb_has_bedrock_rules="true"
    fi
    if jq -e '.Rules[]? | select(.Name | test("agent"; "i"))' "$eb_file" >/dev/null 2>&1; then
        eb_has_agent_rules="true"
    fi
    # Build rules_with_targets array from Phase 2 fetches
    eb_parts=""
    eb_rule_names=$(jq -r '[.Rules[]? | select(.Name | test("bedrock|agent|genai|ai"; "i")) | .Name] | .[0:5] | .[]' "$eb_file" 2>/dev/null || true)
    if [ -n "$eb_rule_names" ]; then
        while IFS= read -r rn; do
            [ -z "$rn" ] && continue
            rn_safe=$(echo "$rn" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
            targets_file="$RAW_DATA_DIR/events-list-targets-${rn_safe}.json"
            tgt_count=0
            if check_result "$targets_file"; then
                tgt_count=$(jq '[.Targets[]?] | length' "$targets_file" 2>/dev/null || echo 0)
            fi
            entry=$(jq -cn --arg name "$rn" --argjson target_count "$tgt_count" '{name: $name, target_count: $target_count}')
            if [ -n "$eb_parts" ]; then
                eb_parts="${eb_parts},${entry}"
            else
                eb_parts="${entry}"
            fi
        done <<< "$eb_rule_names"
    fi
    [ -n "$eb_parts" ] && eb_rules_with_targets="[${eb_parts}]"
fi

# --- SNS (GENOPS02_BP02 — notification targets) ---
sns_topics_file="$RAW_DATA_DIR/sns-list-topics.json"
sns_subs_file="$RAW_DATA_DIR/sns-list-subscriptions.json"
sns_collected="false"
sns_topic_count=0
sns_subscription_count=0
sns_alarms_have_targets="false"
if check_result "$sns_topics_file" || check_result "$sns_subs_file"; then
    sns_collected="true"
fi
if check_result "$sns_topics_file"; then
    sns_topic_count=$(jq '[.Topics[]?] | length' "$sns_topics_file" 2>/dev/null || echo 0)
fi
if check_result "$sns_subs_file"; then
    sns_subscription_count=$(jq '[.Subscriptions[]?] | length' "$sns_subs_file" 2>/dev/null || echo 0)
fi
# Cross-reference alarm_actions: check if any alarm has an SNS target
if check_result "$alarms_file" && [ "$sns_topic_count" -gt 0 ]; then
    if jq -e '.MetricAlarms[]? | select((.AlarmActions // []) | length > 0) | .AlarmActions[]? | select(test("arn:aws:sns"))' "$alarms_file" >/dev/null 2>&1; then
        sns_alarms_have_targets="true"
    fi
fi

# --- AWS Config (GENOPS04_BP01 — governance) ---
config_file="$RAW_DATA_DIR/configservice-describe-configuration-recorders.json"
config_collected="false"
config_recorder_active="false"
config_recorder_count=0
if check_result "$config_file"; then
    config_collected="true"
    config_recorder_count=$(jq '[.ConfigurationRecorders[]?] | length' "$config_file" 2>/dev/null || echo 0)
    if jq -e '.ConfigurationRecorders[]? | select(.recordingGroup.allSupported == true)' "$config_file" >/dev/null 2>&1; then
        config_recorder_active="true"
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
    --argjson agent_model_id "$agent_model_id" \
    --argjson agent_idle_ttl "$agent_idle_ttl" \
    --argjson dash_count "$dash_count" \
    --argjson has_bedrock_dashboard "$has_bedrock_dashboard" \
    --argjson alarms_count "$alarms_count" \
    --argjson bedrock_alarm_count "$bedrock_alarm_count" \
    --argjson lambda_alarm_count "$lambda_alarm_count" \
    --argjson bedrock_alarm_metrics "$bedrock_alarm_metrics" \
    --argjson bedrock_lg_count "$bedrock_lg_count" \
    --argjson lambda_lg_count "$lambda_lg_count" \
    --argjson logging_enabled "$logging_enabled" \
    --arg logging_destination "$logging_destination" \
    --argjson eval_job_count "$eval_job_count" \
    --argjson eval_latest_status "$eval_latest_status" \
    --argjson eval_latest_date "$eval_latest_date" \
    --argjson quota_change_count "$quota_change_count" \
    --argjson has_quota_increases "$has_quota_increases" \
    --argjson custom_model_count "$custom_model_count" \
    --argjson xray_collected "$xray_collected" \
    --argjson xray_sampling_rules_count "$xray_sampling_rules_count" \
    --argjson xray_has_custom_rules "$xray_has_custom_rules" \
    --argjson xray_default_rate "$xray_default_rate" \
    --argjson cw_metrics_collected "$cw_metrics_collected" \
    --argjson cw_bedrock_agentcore_count "$cw_bedrock_agentcore_count" \
    --argjson cw_aws_bedrock_count "$cw_aws_bedrock_count" \
    --argjson cw_has_token_metrics "$cw_has_token_metrics" \
    --argjson cw_has_latency_metrics "$cw_has_latency_metrics" \
    --argjson eb_collected "$eb_collected" \
    --argjson eb_rule_count "$eb_rule_count" \
    --argjson eb_has_bedrock_rules "$eb_has_bedrock_rules" \
    --argjson eb_has_agent_rules "$eb_has_agent_rules" \
    --argjson eb_rules_with_targets "$eb_rules_with_targets" \
    --argjson sns_collected "$sns_collected" \
    --argjson sns_topic_count "$sns_topic_count" \
    --argjson sns_subscription_count "$sns_subscription_count" \
    --argjson sns_alarms_have_targets "$sns_alarms_have_targets" \
    --argjson config_collected "$config_collected" \
    --argjson config_recorder_active "$config_recorder_active" \
    --argjson config_recorder_count "$config_recorder_count" \
    '{
        pillar: "operational_excellence",
        timestamp: $timestamp,
        errors: $errors,
        agent: {
            model_id: $agent_model_id,
            idle_session_ttl: $agent_idle_ttl
        },
        dashboards: {
            count: $dash_count,
            has_bedrock_dashboard: $has_bedrock_dashboard
        },
        alarms: {
            count: $alarms_count,
            bedrock_alarm_count: $bedrock_alarm_count,
            lambda_alarm_count: $lambda_alarm_count,
            bedrock_metric_names: $bedrock_alarm_metrics
        },
        log_groups: {
            bedrock_count: $bedrock_lg_count,
            lambda_count: $lambda_lg_count
        },
        invocation_logging: {
            enabled: $logging_enabled,
            destination: $logging_destination
        },
        evaluation_jobs: {
            count: $eval_job_count,
            latest_status: $eval_latest_status,
            latest_date: $eval_latest_date
        },
        quota_management: {
            change_requests_count: $quota_change_count,
            has_increase_requests: $has_quota_increases
        },
        custom_models: {
            count: $custom_model_count
        },
        xray: {
            collected: $xray_collected,
            sampling_rules_count: $xray_sampling_rules_count,
            has_custom_rules: $xray_has_custom_rules,
            default_rate: $xray_default_rate
        },
        cloudwatch_metrics: {
            collected: $cw_metrics_collected,
            bedrock_agentcore_count: $cw_bedrock_agentcore_count,
            aws_bedrock_count: $cw_aws_bedrock_count,
            has_token_metrics: $cw_has_token_metrics,
            has_latency_metrics: $cw_has_latency_metrics
        },
        eventbridge: {
            collected: $eb_collected,
            rule_count: $eb_rule_count,
            has_bedrock_rules: $eb_has_bedrock_rules,
            has_agent_rules: $eb_has_agent_rules,
            rules_with_targets: $eb_rules_with_targets
        },
        sns: {
            collected: $sns_collected,
            topic_count: $sns_topic_count,
            subscription_count: $sns_subscription_count,
            alarms_have_targets: $sns_alarms_have_targets
        },
        aws_config: {
            collected: $config_collected,
            recorder_active: $config_recorder_active,
            recorder_count: $config_recorder_count
        }
    }' > "$DATA_DIR/ops-ex-summary.json"

progress "ops-ex-summary.json written to ${DATA_DIR}/ops-ex-summary.json"

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------
error_count="${#COLLECTED_ERRORS[@]}"
if [ "$error_count" -gt 0 ]; then
    print_errors || true
    exit 2
fi

exit 0
