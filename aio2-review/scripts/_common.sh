#!/usr/bin/env bash
# _common.sh — Shared library for AIO2 review scripts
#
# Sourced by all scripts in this directory:
#   source "$(dirname "$0")/_common.sh"
#
# Provides: argument parsing, logging, progress reporting, error collection,
# dependency validation, caching (fetch_or_cache / retry_cmd), and report
# appending.  All code is bash 3.2+ compatible (no associative arrays, no
# ${var,,} / ${var^^}, no declare -A).

set -euo pipefail
set -E  # errtrace — ERR trap is inherited by functions and subshells

# ---------------------------------------------------------------------------
# Path resolution — all sibling/parent references derive from SCRIPT_DIR
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Global variable declarations
# ---------------------------------------------------------------------------
REGION=""
AWS_PROFILE=""
PROFILE_ARGS=()          # array form: () or (--profile "<name>"); call sites
                         # expand this as "${PROFILE_ARGS[@]}" next to the aws
                         # subcommand so --profile stays visible at every
                         # invocation while avoiding SC2086 word-splitting.
DATA_DIR=""
RAW_DATA_DIR=""          # "$DATA_DIR/data" — set by validate_data_dir
REMAINING_ARGS=()        # Unknown args left over after parse_common_args
COLLECTED_ERRORS=()      # Accumulated error messages; printed by print_errors

# Registry cache — load_registry stores parsed JSON here so repeat calls
# within one script invocation are free.
AIO2_REGISTRY_TMPFILE="${AIO2_REGISTRY_TMPFILE:-$(mktemp "${TMPDIR:-/tmp}/aio2-registry.XXXXXX")}"

# Lens-index cache — load_lens_index stores the joined lens projection here
# so repeat calls within one script invocation are free.
AIO2_LENS_INDEX_TMPFILE="${AIO2_LENS_INDEX_TMPFILE:-$(mktemp "${TMPDIR:-/tmp}/aio2-lens-index.XXXXXX")}"

# Retry / backoff configuration (can be overridden by the caller before
# sourcing, or via environment variables).
MAX_RETRIES="${MAX_RETRIES:-3}"
INITIAL_BACKOFF_SECONDS="${INITIAL_BACKOFF_SECONDS:-1}"
MAX_JITTER_SECONDS="${MAX_JITTER_SECONDS:-1}"

# ---------------------------------------------------------------------------
# ERR trap — catches unexpected failures
# ---------------------------------------------------------------------------
# Installed here so every script that sources _common.sh gets it for free.
# The handler prints context to stdout (so the orchestrator agent can read it)
# and then calls print_errors to flush any accumulated errors.
#
# Note: functions that intentionally return non-zero (check_result,
# print_errors) should be called with "|| true" or "; rc=$?" at the call
# site to prevent the ERR trap from firing on expected non-zero returns.
__aio2_err_handler() {
    local lineno="$1"
    local exit_code="$2"
    local cmd="$3"
    echo "FATAL: Script failed at line ${lineno} (exit code ${exit_code}): ${cmd}"
    print_errors || true
}

trap '__aio2_err_handler $LINENO $? "${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# Logging helpers — all write to stderr so they don't pollute stdout
# ---------------------------------------------------------------------------
#
# Levels (numerically): debug=0, info=1, warn=2, error=3.
# AIO2_LOG_LEVEL controls the floor: messages below the floor are suppressed.
# Default is "info" so cache hits and other verbose chatter stay quiet unless
# the user opts in via AIO2_LOG_LEVEL=debug or AIO2_VERBOSE=1.
AIO2_LOG_LEVEL="${AIO2_LOG_LEVEL:-info}"
if [ "${AIO2_VERBOSE:-0}" = "1" ]; then
    AIO2_LOG_LEVEL="debug"
fi

__aio2_level_num() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}
AIO2_LOG_LEVEL_NUM=$(__aio2_level_num "$AIO2_LOG_LEVEL")

# log_debug <message...>
# Writes a DEBUG-level timestamped line to stderr (suppressed unless the
# active level is debug). Use for cache hits and other high-volume traces
# that bury real warnings if printed at INFO.
log_debug() {
    [ "$AIO2_LOG_LEVEL_NUM" -le 0 ] || return 0
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] DEBUG $*" >&2
}

# log_info <message...>
# Writes an INFO-level timestamped line to stderr.
log_info() {
    [ "$AIO2_LOG_LEVEL_NUM" -le 1 ] || return 0
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] INFO $*" >&2
}

# log_warn <message...>
# Writes a WARN-level timestamped line to stderr.
log_warn() {
    [ "$AIO2_LOG_LEVEL_NUM" -le 2 ] || return 0
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] WARN $*" >&2
}

# log_error <message...>
# Writes an ERROR-level timestamped line to stderr.
log_error() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] ERROR $*" >&2
}

# ---------------------------------------------------------------------------
# Progress reporting — writes to stdout for the orchestrator agent to read
# ---------------------------------------------------------------------------

# progress <message...>
# Writes a short status message to stdout, prefixed with ">> ".
# Keep to 5-8 calls per script so the agent output stays readable.
progress() {
    echo ">> $*"
}

# ---------------------------------------------------------------------------
# Error collection
# ---------------------------------------------------------------------------

# record_error <message...>
# Appends the message to COLLECTED_ERRORS and also writes it to stderr.
record_error() {
    local msg="$*"
    COLLECTED_ERRORS+=("$msg")
    log_error "$msg"
}

# print_errors
# Outputs all collected errors to stdout (so the orchestrator can see them)
# and returns the error count as the exit code.
# Use "return" not "exit" so callers can decide what to do with the count.
#
# IMPORTANT: Because this function returns a non-zero exit code when errors
# exist, callers under set -e must use one of:
#   print_errors || true          (ignore the count)
#   print_errors; rc=$?           (capture the count)
print_errors() {
    local count="${#COLLECTED_ERRORS[@]}"
    if [ "$count" -gt 0 ]; then
        echo "--- Collected errors (${count}) ---"
        local i=0
        while [ "$i" -lt "$count" ]; do
            echo "  [error] ${COLLECTED_ERRORS[$i]}"
            i=$((i + 1))
        done
        echo "--- End of errors ---"
    fi
    return "$count"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# parse_common_args "$@"
# Parses --region, --profile, --data-dir, and --help from the argument list.
# Unknown arguments are accumulated in REMAINING_ARGS for the calling script
# to handle.  Sets PROFILE_ARGS to (--profile "<name>") when --profile is
# provided, or to () when it is omitted.
#
# Usage:
#   parse_common_args "$@"
#   # Then handle REMAINING_ARGS for script-specific flags.
parse_common_args() {
    REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --region)
                REGION="${2:-}"
                shift 2
                ;;
            --region=*)
                REGION="${1#--region=}"
                shift
                ;;
            --profile)
                AWS_PROFILE="${2:-}"
                shift 2
                ;;
            --profile=*)
                AWS_PROFILE="${1#--profile=}"
                shift
                ;;
            --data-dir)
                DATA_DIR="${2:-}"
                shift 2
                ;;
            --data-dir=*)
                DATA_DIR="${1#--data-dir=}"
                shift
                ;;
            --help|-h)
                # Let the calling script handle --help by putting it in
                # REMAINING_ARGS so it can print its own usage message.
                REMAINING_ARGS+=("$1")
                shift
                ;;
            *)
                REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Build PROFILE_ARGS after parsing so it reflects the final value.
    # Expand it as "${PROFILE_ARGS[@]}" at each aws invocation.
    if [ -n "$AWS_PROFILE" ]; then
        PROFILE_ARGS=(--profile "$AWS_PROFILE")
    else
        PROFILE_ARGS=()
    fi
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

# validate_common_args
# Verifies that REGION is set and matches the basic AWS region format
# (e.g., us-east-1, ap-southeast-2, eu-central-1).
# Exits with code 1 on failure.
validate_common_args() {
    if [ -z "$REGION" ]; then
        echo "ERROR: --region is required" >&2
        exit 1
    fi
    # Bash 3.2-compatible regex check via grep (no =~ with complex patterns
    # that differ between bash versions).
    # Pattern covers:
    #   Standard regions:  us-east-1, eu-central-1, ap-southeast-2
    #   GovCloud:          us-gov-west-1, us-gov-east-1
    #   ISO/ISOB:          us-iso-east-1, us-isob-east-1
    # Rule: starts with 2 lowercase letters, followed by one or more hyphen-
    # separated lowercase segments, ending with a hyphen and a digit.
    if ! echo "$REGION" | grep -qE '^[a-z]{2}(-[a-z]+)+-[0-9]+$'; then
        echo "ERROR: Invalid AWS region format: '${REGION}'. Expected format like us-east-1 or ap-southeast-2." >&2
        exit 1
    fi
}

# validate_data_dir
# Verifies DATA_DIR is set and the directory exists.
# Creates $DATA_DIR/data/ if it does not already exist.
# Sets RAW_DATA_DIR="$DATA_DIR/data".
# Exits with code 1 on failure.
validate_data_dir() {
    if [ -z "$DATA_DIR" ]; then
        echo "ERROR: --data-dir is required" >&2
        exit 1
    fi
    if [ ! -d "$DATA_DIR" ]; then
        echo "ERROR: Data directory does not exist: ${DATA_DIR}" >&2
        exit 1
    fi
    RAW_DATA_DIR="${DATA_DIR}/data"
    if [ ! -d "$RAW_DATA_DIR" ]; then
        mkdir -p "$RAW_DATA_DIR"
        log_info "Created raw data directory: ${RAW_DATA_DIR}"
    fi
}

# validate_aws_credentials
# Verifies that AWS credentials are available and valid by running
# sts get-caller-identity.  Exits with code 1 and a human-friendly message
# when credentials are missing or expired so the user knows to run
# "aws login" (or "aws configure") before retrying.
#
# On success, sets the following globals for callers that need them:
#   VALIDATED_ACCOUNT_ID   — AWS account ID from the STS response
#   VALIDATED_IDENTITY_ARN — caller identity ARN from the STS response
#
# Usage: call after validate_common_args (REGION and PROFILE_ARGS must be set).
VALIDATED_ACCOUNT_ID=""
VALIDATED_IDENTITY_ARN=""

validate_aws_credentials() {
    local sts_out sts_rc
    set +e
    sts_out=$(aws "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" sts get-caller-identity --region "$REGION" --output json 2>&1)
    sts_rc=$?
    set -e

    if [ "$sts_rc" -ne 0 ]; then
        # Check for the specific "no credentials" message and surface a clear
        # actionable error; fall back to the raw AWS error for other failures.
        if echo "$sts_out" | grep -qi "unable to locate credentials\|no credentials\|could not be found"; then
            echo "FATAL: Unable to locate credentials. You can configure credentials by running \"aws login\"." >&2
            echo "I can see you're not currently authenticated to AWS. That means I can't run the cloud portion of the review right now." >&2
        else
            echo "FATAL: AWS credential validation failed:" >&2
            echo "$sts_out" >&2
        fi
        exit 1
    fi

    VALIDATED_ACCOUNT_ID=$(echo "$sts_out" | jq -r '.Account // empty' 2>/dev/null || echo "")
    VALIDATED_IDENTITY_ARN=$(echo "$sts_out" | jq -r '.Arn // empty' 2>/dev/null || echo "")

    if [ -z "$VALIDATED_ACCOUNT_ID" ] || [ -z "$VALIDATED_IDENTITY_ARN" ]; then
        echo "FATAL: Could not extract Account ID or Identity ARN from sts get-caller-identity" >&2
        exit 1
    fi

    log_info "Credentials validated. Account: ${VALIDATED_ACCOUNT_ID}, Identity: ${VALIDATED_IDENTITY_ARN}"
}

# validate_deps
# Checks that aws and jq are available in PATH.
# Calls record_error for each missing dependency (with install URL).
# Exits with code 1 if any dependency is missing.
validate_deps() {
    local missing=0

    if ! command -v aws >/dev/null 2>&1; then
        record_error "Missing dependency: 'aws' (AWS CLI) not found in PATH. Install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        missing=1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        record_error "Missing dependency: 'jq' not found in PATH. Install from https://stedolan.github.io/jq/download/"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        print_errors || true
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Registry loading
# ---------------------------------------------------------------------------

# load_registry [<active-frameworks>]
# Reads ${SKILL_ROOT}/references/check-registry.json.  When <active-frameworks>
# is given (comma-separated list of framework keys, e.g. "WA,NIST"), filters
# to entries whose "frameworks" array intersects the list.  Outputs the
# resulting JSON array on stdout.
#
# Caches the parsed (and optionally filtered) result in $AIO2_REGISTRY_TMPFILE
# so repeat calls within one script are free.
#
# Requirements: 1.2, 2.1
load_registry() {
    local active_frameworks="${1:-}"

    # Return cached result if available.
    if [ -f "$AIO2_REGISTRY_TMPFILE" ] && [ -s "$AIO2_REGISTRY_TMPFILE" ]; then
        cat "$AIO2_REGISTRY_TMPFILE"
        return 0
    fi

    # Resolve the registry path relative to SCRIPT_DIR (sibling resolver).
    local skill_root
    skill_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local registry_file="${skill_root}/references/check-registry.json"

    if [ ! -f "$registry_file" ]; then
        log_error "Registry not found: ${registry_file}"
        echo "[]"
        return 1
    fi

    local result
    if [ -z "$active_frameworks" ]; then
        # No filtering — return the full checks array.
        result=$(jq '.checks' "$registry_file")
    else
        # Filter: keep entries whose "frameworks" array intersects the
        # comma-separated active_frameworks list.
        # Convert comma-separated string to a JSON array for jq.
        local frameworks_json
        frameworks_json=$(printf '%s' "$active_frameworks" | jq -R 'split(",")')

        result=$(jq --argjson af "$frameworks_json" '
            [ .checks[] | select(
                .frameworks as $f |
                ($af | any(. as $a | $f | index($a) != null))
            ) ]
        ' "$registry_file")
    fi

    # Cache and emit.
    printf '%s\n' "$result" > "$AIO2_REGISTRY_TMPFILE"
    printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Lens index loader
# ---------------------------------------------------------------------------

# load_lens_index
# Builds a flat lookup keyed by check_id from the lens JSON files:
#   references/generative-ai-lens.json       (upstream WA GenAI Lens)
#   references/nist-ai-rmf-lens.json         (generated from NIST YAML)
#   references/finops-ai-lens.json           (generated from FinOps YAML)
#
# Each lens follows the same grammar: pillars[].questions[].choices[]. For
# every choice (best practice / check) the loader emits one object:
#   {
#     check_id, lens_name, pillar_id, pillar_name, question_id,
#     question_title, question_description, title, display_text, url,
#     improvement_text, improvement_url
#   }
#
# The result is a JSON array printed on stdout and cached in
# $AIO2_LENS_INDEX_TMPFILE. Choices ending in `_no` (the "None of these"
# placeholder used by the upstream WA grammar) are excluded.
#
# Callers that need a quick lookup can pipe the result through
# `jq 'map({key: .check_id, value: .}) | from_entries'`.
load_lens_index() {
    if [ -f "$AIO2_LENS_INDEX_TMPFILE" ] && [ -s "$AIO2_LENS_INDEX_TMPFILE" ]; then
        cat "$AIO2_LENS_INDEX_TMPFILE"
        return 0
    fi

    local skill_root
    skill_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local ref_dir="${skill_root}/references"

    local lens_files=(
        "${ref_dir}/generative-ai-lens.json"
        "${ref_dir}/nist-ai-rmf-lens.json"
        "${ref_dir}/finops-ai-lens.json"
    )

    local existing=()
    local f
    for f in "${lens_files[@]}"; do
        if [ -f "$f" ]; then
            existing+=("$f")
        else
            log_warn "load_lens_index: lens not found: ${f}"
        fi
    done

    if [ "${#existing[@]}" -eq 0 ]; then
        echo "[]"
        return 1
    fi

    # Slurp every lens, fold into a flat array of per-choice records.
    local result
    result=$(jq -s '
        [ .[] as $lens
          | $lens.pillars[]? as $p
          | $p.questions[]? as $q
          | $q.choices[]? as $c
          | select(($c.id // "") | endswith("_no") | not)
          | {
              check_id:             ($c.id // ""),
              lens_name:            ($lens.name // ""),
              pillar_id:            ($p.id // ""),
              pillar_name:          ($p.name // ""),
              question_id:          ($q.id // ""),
              question_title:       ($q.title // ""),
              question_description: ($q.description // ""),
              title:                ($c.title // ""),
              display_text:         (($c.helpfulResource.displayText // "")),
              url:                  (($c.helpfulResource.url // "")),
              improvement_text:     (($c.improvementPlan.displayText // "")),
              improvement_url:      (($c.improvementPlan.url // ""))
            }
        ]
    ' "${existing[@]}")

    printf '%s\n' "$result" > "$AIO2_LENS_INDEX_TMPFILE"
    printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Filename sanitization
# ---------------------------------------------------------------------------

# safe_id <identifier>
# Sanitizes an identifier (which may be a full ARN) for safe use in filenames.
# Replaces colons (:) and slashes (/) with underscores (_).
# Example: "arn:aws:bedrock:us-east-1:123456:guardrail/abc123"
#       → "arn_aws_bedrock_us-east-1_123456_guardrail_abc123"
safe_id() {
    echo "$1" | tr '/:' '__'
}

# ---------------------------------------------------------------------------
# Retry logic
# ---------------------------------------------------------------------------

# retry_cmd <max_retries> <cmd...>
# Executes <cmd...> and captures combined stdout+stderr.
#
# On success:          echoes output to stdout, returns 0.
# On non-retryable error (AccessDeniedException, UnauthorizedException,
#   InvalidParameterException, ValidationException,
#   ResourceNotFoundException, NoSuchEntityException,
#   UnrecognizedClientException, ExpiredTokenException,
#   InvalidParameterValueException):
#                      calls record_error, returns 0 with empty output.
# On retryable failure: sleeps with exponential backoff + jitter, retries
#   up to <max_retries> times.
# After exhausting retries: calls record_error, returns 0 with empty output
#   (caller uses check_result to detect the failure).
#
# Returns 0 in all cases so that fetch_or_cache can decide what to write.
retry_cmd() {
    local max_retries="$1"
    shift
    local cmd_str="$*"

    local attempt=0
    local backoff="$INITIAL_BACKOFF_SECONDS"
    local output=""
    local exit_code=0

    while [ "$attempt" -le "$max_retries" ]; do
        # Capture stdout+stderr together; suppress ERR trap and errtrace so
        # the trap doesn't fire inside the $(...) subshell on expected failures.
        set +eE
        output=$("$@" 2>&1)
        exit_code=$?
        set -eE

        if [ "$exit_code" -eq 0 ]; then
            echo "$output"
            return 0
        fi

        # Check for non-retryable errors.
        if echo "$output" | grep -qE \
            'AccessDeniedException|UnauthorizedException|InvalidParameterException|ValidationException|ResourceNotFoundException|NoSuchEntityException|UnrecognizedClientException|ExpiredTokenException|InvalidParameterValueException|NoSuchLifecycleConfiguration|NoSuchBucketPolicy|NoSuchCORSConfiguration|NoSuchWebsiteConfiguration|ServerSideEncryptionConfigurationNotFoundError|NoSuchTagSet|ReplicationConfigurationNotFoundError'; then
            record_error "Non-retryable error running: ${cmd_str} — ${output}"
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -le "$max_retries" ]; then
            # Exponential backoff with random jitter.
            # Use awk for arithmetic to stay bash 3.2 compatible and avoid
            # floating-point issues with $(( )).
            local jitter
            jitter=$(awk -v max="$MAX_JITTER_SECONDS" 'BEGIN { srand(); printf "%d", int(rand() * (max + 1)) }')
            local sleep_time
            sleep_time=$((backoff + jitter))
            log_warn "Command failed (attempt ${attempt}/${max_retries}), retrying in ${sleep_time}s: ${cmd_str}"
            sleep "$sleep_time"
            backoff=$((backoff * 2))
        fi
    done

    record_error "Command failed after ${max_retries} retries: ${cmd_str} — ${output}"
    return 0
}

# ---------------------------------------------------------------------------
# Caching
# ---------------------------------------------------------------------------

# fetch_or_cache <output_file> <cmd...>
# Checks whether <output_file> already contains valid, non-null JSON AND its
# sibling .meta file matches the current invocation's scope (account_id,
# region, solution_name, input_type). If both checks pass, logs a cache hit
# and returns 0 without running the command.
#
# Otherwise, runs retry_cmd and writes the result to <output_file>, then
# writes a fresh .meta sidecar describing this invocation. On empty output or
# failure, writes "null" to <output_file> and calls record_error so the
# caller can detect the failure via check_result.
#
# The .meta sidecar prevents stale files from a previous run (different
# solution / account / region) from being silently re-served when a data
# directory is reused. Mismatched meta forces a fresh fetch.
#
# Scope variables consulted (any may be empty — empty values match each
# other so unscoped utility scripts are unaffected):
#   ACCOUNT_ID, REGION, SOLUTION_NAME, INPUT_TYPE
#
# In all cases the file exists after this function returns, and the script
# does NOT terminate due to a command failure (set +e / set -e guards).
fetch_or_cache() {
    local output_file="$1"
    shift
    local cmd_str="$*"
    local meta_file="${output_file}.meta"

    # Build the current scope signature.
    local cur_account="${ACCOUNT_ID:-}"
    local cur_region="${REGION:-}"
    local cur_solution="${SOLUTION_NAME:-}"
    local cur_input_type="${INPUT_TYPE:-}"
    local cur_meta="${cur_account}|${cur_region}|${cur_solution}|${cur_input_type}"

    # Cache hit: file exists, is non-empty, content is not "null", is valid
    # JSON, and the sibling .meta matches the current scope. If a .meta is
    # missing (older cache) we accept the file but rewrite the meta so future
    # cache hits validate.
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local content
        content=$(cat "$output_file")
        if [ "$content" != "null" ] && echo "$content" | jq empty >/dev/null 2>&1; then
            local cached_meta=""
            if [ -f "$meta_file" ]; then
                cached_meta=$(cat "$meta_file" 2>/dev/null || echo "")
            fi
            if [ -z "$cached_meta" ]; then
                # Legacy file with no meta — accept and stamp it.
                echo "$cur_meta" > "$meta_file"
                log_debug "Cache hit (stamped legacy meta): ${output_file}"
                return 0
            fi
            if [ "$cached_meta" = "$cur_meta" ]; then
                log_debug "Cache hit: ${output_file}"
                return 0
            fi
            log_warn "Cache scope mismatch — refetching: ${output_file} (cached=${cached_meta} current=${cur_meta})"
            # Fall through to re-fetch below.
        fi
    fi

    # Run the command, suppressing the ERR trap so a failure does not abort
    # the script before we can write "null" and record the error.
    # retry_cmd always returns 0 (it records errors internally rather than
    # propagating a non-zero exit), so there is no exit code to capture here.
    set +eE
    local result
    result=$(retry_cmd "$MAX_RETRIES" "$@")
    set -eE

    if [ -n "$result" ] && [ "$result" != "null" ] && echo "$result" | jq empty >/dev/null 2>&1; then
        echo "$result" > "$output_file"
        echo "$cur_meta" > "$meta_file"
        log_info "Fetched and cached: ${output_file}"
    else
        # Write "null" so subsequent cache checks know the fetch was attempted.
        echo "null" > "$output_file"
        # Stamp meta even on failure so the next run with the same scope
        # short-circuits instead of retrying every time.
        echo "$cur_meta" > "$meta_file"
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            # Non-empty but invalid JSON — record the raw output as an error.
            record_error "Invalid JSON output for ${output_file}: ${result}"
        else
            # Empty output or already "null" — error already recorded by retry_cmd
            # if the command failed; just ensure the file is written.
            :
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Result validation
# ---------------------------------------------------------------------------

# check_result <file>
# Returns 0 if <file> exists, is non-empty, its content is not the JSON
# literal "null", and it contains valid JSON.
# Returns 1 otherwise.
check_result() {
    local file="$1"
    local _cr_ok=0
    if [ ! -f "$file" ]; then
        _cr_ok=1
    elif [ ! -s "$file" ]; then
        _cr_ok=1
    else
        local content
        content=$(cat "$file")
        # Strip whitespace to detect whitespace-only files
        local trimmed
        trimmed=$(echo "$content" | tr -d '[:space:]')
        if [ -z "$trimmed" ] || [ "$trimmed" = "null" ]; then
            _cr_ok=1
        elif ! echo "$content" | jq empty >/dev/null 2>&1; then
            _cr_ok=1
        fi
    fi
    return "$_cr_ok"
}

# ---------------------------------------------------------------------------
# Bedrock Agent versioning helpers
# ---------------------------------------------------------------------------

# resolve_agent_versions <agent_id> <raw_data_dir> [aliases_file_override]
# Returns (on stdout) the set of agent versions that should be queried for
# action groups, knowledge bases, etc. This is the union of:
#   - every version referenced by an alias's routingConfiguration
#   - every PREPARED numbered version returned by list-agent-versions
#     (caught even if no alias currently routes to it — important when the
#     agent has been promoted but the alias hasn't been updated)
#   - "DRAFT" (always included as a fallback so we catch in-progress edits)
#
# The result is newline-separated and deduplicated, with numbered versions
# tried before DRAFT (so callers iterating in order hit the deployed version
# first).
#
# Why: Bedrock agents version their action groups and KB associations. DRAFT
# is the mutable working copy; numbered versions are immutable snapshots; and
# aliases route traffic to a version. Querying only DRAFT misses what's
# actually deployed when an alias points to a numbered version. Querying only
# aliased versions misses promoted versions whose alias hasn't been updated.
#
# The function caches list-agent-aliases and list-agent-versions output under
# <raw_data_dir>/ unless a pre-fetched aliases file is passed as the third
# argument.
#
# Callers must have REGION and PROFILE_ARGS set (standard for all scripts,
# via parse_common_args).
resolve_agent_versions() {
    local agent_id="$1"
    local raw_dir="$2"
    local aliases_file="${3:-${raw_dir}/bedrock-agent-list-agent-aliases-${agent_id}.json}"
    local versions_file="${raw_dir}/bedrock-agent-list-agent-versions-${agent_id}.json"

    # Fetch aliases if we don't already have them.
    if ! check_result "$aliases_file" 2>/dev/null; then
        fetch_or_cache "$aliases_file" \
            aws "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" bedrock-agent list-agent-aliases \
                --agent-id "$agent_id" \
                --region "$REGION" --output json
    fi

    # Fetch the version list (cheap; one call per agent).
    if ! check_result "$versions_file" 2>/dev/null; then
        fetch_or_cache "$versions_file" \
            aws "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" bedrock-agent list-agent-versions \
                --agent-id "$agent_id" \
                --region "$REGION" --output json
    fi

    # Aliased versions (may be empty if the call failed or no aliases).
    local aliased_versions=""
    if check_result "$aliases_file" 2>/dev/null; then
        aliased_versions=$(jq -r '
            .agentAliasSummaries[]?
            | .routingConfiguration[]?
            | .agentVersion // empty
        ' "$aliases_file" 2>/dev/null || true)
    fi

    # Numbered PREPARED versions (skip DRAFT — added below as the fallback).
    local prepared_versions=""
    if check_result "$versions_file" 2>/dev/null; then
        prepared_versions=$(jq -r '
            .agentVersionSummaries[]?
            | select(.agentStatus == "PREPARED")
            | select(.agentVersion != "DRAFT")
            | .agentVersion // empty
        ' "$versions_file" 2>/dev/null || true)
    fi

    # Emit numbered first (so callers iterating in order see the deployed
    # version before DRAFT), then DRAFT, deduplicated. awk preserves order.
    {
        if [ -n "$aliased_versions" ]; then
            echo "$aliased_versions"
        fi
        if [ -n "$prepared_versions" ]; then
            echo "$prepared_versions"
        fi
        echo "DRAFT"
    } | awk 'NF && !seen[$0]++'
}

# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Working directory helpers
# ---------------------------------------------------------------------------

# work_dir <data_dir> [<subdir>]
# Returns (on stdout) a path inside <data_dir>/_work/, creating the directory
# on first use. Optional <subdir> is appended (e.g., "findings", "drafts",
# "cache"). The _work/ tree quarantines transient agent-authored input so it
# stays out of the canonical report.json/md/html and the raw data/ tree.
#
# Examples:
#   FINDINGS_DIR=$(work_dir "$DATA_DIR" findings)
#   DRAFTS_DIR=$(work_dir "$DATA_DIR" drafts)
work_dir() {
    local data_dir="$1"
    local sub="${2:-}"
    local target="${data_dir}/_work"
    if [ -n "$sub" ]; then
        target="${target}/${sub}"
    fi
    [ -d "$target" ] || mkdir -p "$target"
    printf '%s' "$target"
}

# manifest_get <data_dir> <jq_filter>
# Reads <data_dir>/manifest.json and applies the given jq filter, returning
# the result on stdout. Used by pillar scripts to pull resource IDs directly
# from the manifest instead of accepting them all as command-line flags.
#
# Returns empty (and exits 0) if the manifest is missing or the filter
# matches nothing — callers handle the empty case as "no resources of this
# type, skip the relevant CLI calls".
#
# Examples:
#   AGENT_IDS_CSV=$(manifest_get "$DATA_DIR" '.agent_ids | join(",")')
#   FIRST_AGENT=$(manifest_get "$DATA_DIR" '.agent_ids[0] // ""')
manifest_get() {
    local data_dir="$1"
    local filter="$2"
    local manifest="${data_dir}/manifest.json"
    if [ ! -f "$manifest" ]; then
        return 0
    fi
    jq -r "$filter" "$manifest" 2>/dev/null || true
}

# manifest_load_resource_ids <data_dir>
# Populates a standard set of script-local variables from manifest.json so
# pillar scripts don't need a flag per resource family. Each variable is set
# only if it is empty, so explicit --foo-ids flags still take precedence over
# the manifest. Variables set:
#
#   AGENT_ID            — first agent ID (most pillars only need one)
#   AGENT_IDS_CSV       — all agent IDs comma-separated
#   KB_IDS_RAW          — knowledge-base IDs CSV
#   GUARDRAIL_IDS_RAW   — guardrail IDs CSV
#   FLOW_IDS_RAW        — flow IDs CSV
#   ROLE_NAMES_RAW      — IAM role names CSV
#   LAMBDA_NAMES_RAW    — Lambda function names CSV
#   ENDPOINT_NAMES_RAW  — SageMaker endpoint names CSV
#   ENDPOINT_CONFIG_NAMES_RAW
#   TRAIL_ARNS_RAW      — CloudTrail trail ARNs CSV
#   USER_POOL_IDS_RAW   — Cognito user pool IDs CSV
#   CUSTOM_MODEL_IDS_RAW
#   PROMPT_IDS_RAW      — Bedrock Prompt IDs CSV
#   AGENTCORE_RUNTIME_IDS_RAW
#   AGENTCORE_GATEWAY_IDS_RAW
#   AGENTCORE_IDENTITY_IDS_RAW
#   AGENTCORE_MEMORY_IDS_RAW
#   ACCOUNT_ID
#
# Each *_RAW variable is also assigned to its non-suffixed alias the script
# expects (e.g., GUARDRAIL_IDS), so legacy code paths keep working without
# additional shims.
manifest_load_resource_ids() {
    local data_dir="$1"
    local manifest="${data_dir}/manifest.json"
    if [ ! -f "$manifest" ]; then
        return 0
    fi

    : "${AGENT_ID:=$(jq -r '.agent_ids[0] // ""' "$manifest" 2>/dev/null)}"
    : "${AGENT_IDS_CSV:=$(jq -r '(.agent_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${KB_IDS_RAW:=$(jq -r '(.kb_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${GUARDRAIL_IDS_RAW:=$(jq -r '(.guardrail_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${FLOW_IDS_RAW:=$(jq -r '(.flow_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${ROLE_NAMES_RAW:=$(jq -r '(.role_names // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${LAMBDA_NAMES_RAW:=$(jq -r '(.lambda_names // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${ENDPOINT_NAMES_RAW:=$(jq -r '(.endpoint_names // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${ENDPOINT_CONFIG_NAMES_RAW:=$(jq -r '(.endpoint_config_names // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${TRAIL_ARNS_RAW:=$(jq -r '(.trail_arns // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${USER_POOL_IDS_RAW:=$(jq -r '(.user_pool_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${CUSTOM_MODEL_IDS_RAW:=$(jq -r '(.custom_model_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${PROMPT_IDS_RAW:=$(jq -r '(.prompt_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${AGENTCORE_RUNTIME_IDS_RAW:=$(jq -r '(.agentcore_runtime_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${AGENTCORE_GATEWAY_IDS_RAW:=$(jq -r '(.agentcore_gateway_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${AGENTCORE_IDENTITY_IDS_RAW:=$(jq -r '(.agentcore_identity_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${AGENTCORE_MEMORY_IDS_RAW:=$(jq -r '(.agentcore_memory_ids // []) | join(",")' "$manifest" 2>/dev/null)}"
    : "${ACCOUNT_ID:=$(jq -r '.account_id // ""' "$manifest" 2>/dev/null)}"
    : "${SOLUTION_NAME:=$(jq -r '.solution_name // ""' "$manifest" 2>/dev/null)}"
    : "${INPUT_TYPE:=$(jq -r '.input_type // ""' "$manifest" 2>/dev/null)}"

    # Compute the AgentCore-presence flag from the four AgentCore arrays so
    # pillar scripts can short-circuit AgentCore CLI calls when none of these
    # resources exist in scope. Set to 0 by default so unset == not present.
    AGENTCORE_PRESENT=0
    if [ -n "$AGENTCORE_RUNTIME_IDS_RAW" ] \
       || [ -n "$AGENTCORE_GATEWAY_IDS_RAW" ] \
       || [ -n "$AGENTCORE_IDENTITY_IDS_RAW" ] \
       || [ -n "$AGENTCORE_MEMORY_IDS_RAW" ]; then
        AGENTCORE_PRESENT=1
    fi
}

# purge_out_of_scope_data <data_dir>
# Removes raw data files that cannot belong to the current scope. Today this
# scrubs AgentCore artifacts when AGENTCORE_PRESENT=0. The function is safe
# to call repeatedly and is a no-op when the relevant scope is in use.
#
# Why: fetch_or_cache now stamps a .meta sidecar with the current scope and
# refuses to reuse a file from a different scope, but that defence is only
# triggered when a script attempts to read the cached file. Stale files left
# behind from a previous run (different solution in the same data dir) would
# otherwise sit there and confuse anyone browsing data/.
purge_out_of_scope_data() {
    local data_dir="$1"
    local raw="${data_dir}/data"
    [ -d "$raw" ] || return 0

    if [ "${AGENTCORE_PRESENT:-0}" -eq 0 ]; then
        # No AgentCore in scope — remove any AgentCore artifacts.
        local f
        for f in "$raw"/bedrock-agentcore-control-*.json "$raw"/bedrock-agentcore-control-*.json.meta; do
            if [ -f "$f" ]; then
                rm -f "$f"
                log_debug "Purged out-of-scope file: ${f}"
            fi
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Report appending
# ---------------------------------------------------------------------------

# append_report <report_file> <content>
# Appends <content> to <report_file>.
# Uses flock(1) for atomic file locking when available (Linux), falls back
# to a direct append on platforms without flock (macOS without brew util-linux).
# Lock file: ${report_file}.lock
append_report() {
    local report_file="$1"
    local content="$2"
    local lock_file="${report_file}.lock"

    if command -v flock >/dev/null 2>&1; then
        # Open the lock file on fd 200 and acquire an exclusive lock with a
        # 10-second timeout, then append.
        (
            flock -w 10 200 || {
                log_warn "Could not acquire lock on ${lock_file} within 10s; appending without lock"
                echo "$content" >> "$report_file"
                return 0
            }
            echo "$content" >> "$report_file"
        ) 200>"$lock_file"
    else
        # flock not available (macOS without util-linux) — direct append.
        echo "$content" >> "$report_file"
    fi
}

# ---------------------------------------------------------------------------
# Deterministic derivation functions (R1)
# ---------------------------------------------------------------------------
# Pure functions for deterministic parent-check status/risk derivation.
# Used by merge-findings.sh (recompute on change) and validate-report.sh
# (verify the rollup). No side effects, no file I/O — only stdin/stdout.

# status_to_bool <status>
# Maps a Status_Value to a boolean string for riskRules evaluation.
# PASS → "true"; everything else (FAIL, PARTIAL, N/A, PENDING, absent/empty)
# → "false". A sub-check absent from findings[] is treated as non-PASS →
# "false", which is deterministic and self-corrects as more sub-checks merge.
# PENDING is mapped immediately (not deferred).
# Requirements: 1.3, 1.4
status_to_bool() {
  case "$1" in
    PASS) echo "true" ;;
    *)    echo "false" ;;
  esac
}

# risk_to_status <risk>
# Maps a Risk_Value to its corresponding Status_Value.
# NO_RISK → PASS, MEDIUM_RISK → PARTIAL, HIGH_RISK → FAIL.
# Requirements: 1.7
risk_to_status() {
  case "$1" in
    NO_RISK)     echo "PASS" ;;
    MEDIUM_RISK) echo "PARTIAL" ;;
    HIGH_RISK)   echo "FAIL" ;;
  esac
}

# eval_risk_condition <condition> <statusmap_json>
# Evaluates one riskRules condition to "true" or "false".
# <statusmap_json> is a JSON object { "CHECK_ID": "STATUS", ... }.
# The condition is translated to a jq boolean expression via awk and evaluated
# with jq -n. The caller handles the "default" condition (always-true fallback);
# this function is not called for "default".
# Grammar guard: rejects conditions outside the supported token set
# [A-Za-z][A-Za-z0-9_]*, &&, ||, !, (, ), and whitespace — logs and returns 2.
# Requirements: 1.5, 1.10, 1.13
eval_risk_condition() {
  local cond="$1" statusmap="$2"

  # Build the boolean operand map: { id: satisfied? } as true/false.
  # An operand is "satisfied" when its sub-check is PASS OR N/A (not applicable).
  # Treating N/A as neutral (true) prevents an inapplicable best practice from
  # tripping a `!BP` HIGH_RISK rule. The all-N/A case (the whole question is
  # inapplicable) is short-circuited to an N/A parent by the callers
  # (recompute_parent_rollups / derive_parent_status) before this is reached.
  local boolmap
  boolmap=$(printf '%s' "$statusmap" \
    | jq -c 'with_entries(.value = (.value == "PASS" or .value == "N/A"))')

  # Grammar guard (R1.5/R1.10): reject anything outside the supported grammar
  # so we never silently mis-evaluate. Allowed: identifiers, && || ! ( ) and ws.
  if printf '%s' "$cond" \
       | grep -Eqv '^[[:space:]]*([A-Za-z][A-Za-z0-9_]*|&&|\|\||!|\(|\))([[:space:]]|[A-Za-z0-9_&|!()])*$'; then
    log_error "unsupported riskRules condition: ${cond}"
    return 2
  fi

  # Translate condition → jq boolean expression via a single awk pass.
  # Translation rules:
  #   && → " and "
  #   || → " or "
  #   !IDENT → ($b["IDENT"]|not)
  #   bare IDENT → $b["IDENT"]
  #   ( ) and whitespace pass through unchanged.
  local expr
  expr=$(printf '%s' "$cond" | awk '
    {
      out=""; i=1; n=length($0)
      while (i<=n) {
        c=substr($0,i,1)
        if (c=="&") { if (substr($0,i,2)=="&&"){out=out" and "; i+=2; continue} }
        if (c=="|") { if (substr($0,i,2)=="||"){out=out" or ";  i+=2; continue} }
        if (c=="!") {
          # capture the identifier that follows (skip optional whitespace)
          j=i+1; while(j<=n && substr($0,j,1) ~ /[ ]/) j++
          id=""; while(j<=n && substr($0,j,1) ~ /[A-Za-z0-9_]/){id=id substr($0,j,1); j++}
          out=out "($b[\"" id "\"]|not)"; i=j; continue
        }
        if (c ~ /[A-Za-z]/) {
          id=c; j=i+1; while(j<=n && substr($0,j,1) ~ /[A-Za-z0-9_]/){id=id substr($0,j,1); j++}
          out=out "$b[\"" id "\"]"; i=j; continue
        }
        out=out c; i++
      }
      print out
    }')

  # Evaluate the translated expression with jq; prints "true" or "false".
  jq -n --argjson b "$boolmap" "$expr"
}

# derive_parent_risk <lens_file> <question_id> <statusmap_json>
# Reads the question's riskRules from the lens (read-only), walks them in array
# order, and returns the risk of the FIRST condition that evaluates true.
# `default` is treated as an unconditional true (R1.5) and, being last, is the
# fallback (R1.6). Empty/absent rules → echo empty string and return 0 so the
# caller can use the 1:1 pass-through branch (R1.8).
# Requirements: 1.2, 1.5, 1.6, 1.9, 1.13
derive_parent_risk() {
  local lens="$1" qid="$2" statusmap="$3"
  local rules
  rules=$(jq -c --arg q "$qid" '
    .pillars[]?.questions[]? | select(.id==$q) | (.riskRules // [])' "$lens")

  # No rules → caller uses derive_parent_status' 1:1 branch (R1.8).
  [ "$(printf '%s' "$rules" | jq 'length')" -eq 0 ] && { echo ""; return 0; }

  local n i cond risk
  n=$(printf '%s' "$rules" | jq 'length')
  i=0
  while [ "$i" -lt "$n" ]; do
    cond=$(printf '%s' "$rules" | jq -r ".[$i].condition")
    risk=$(printf '%s' "$rules" | jq -r ".[$i].risk")
    if [ "$cond" = "default" ] \
       || [ "$(eval_risk_condition "$cond" "$statusmap")" = "true" ]; then
      echo "$risk"; return 0
    fi
    i=$((i + 1))
  done
  echo ""   # no rule matched and no default — should not happen in the lens
}

# derive_parent_status <lens_file> <question_id> <statusmap_json>
# Derives the overall status for a parent check (lens question).
# - riskRules empty/absent → status of the single sub-check, the
#   NIST/FinOps 1:1 case where the choice id equals the question id (R1.8).
# - riskRules present:
#     * all applicable sub-checks N/A → N/A
#     * any applicable sub-check FAIL → FAIL (a failed best practice is never
#       masked by the lens risk weighting; risk itself stays from the lens)
#     * any applicable sub-check PENDING → PENDING (an unresolved child leaves
#       the parent unresolved; FAIL outranks PENDING)
#     * otherwise → risk_to_status(derive_parent_risk(...))   (R1.7)
# Requirements: 1.7, 1.8, 1.13
derive_parent_status() {
  local lens="$1" qid="$2" statusmap="$3"
  local rules_len
  rules_len=$(jq --arg q "$qid" '
    [.pillars[]?.questions[]? | select(.id==$q) | (.riskRules // [])[]] | length' "$lens")
  if [ "$rules_len" -eq 0 ]; then
    # 1:1: the single choice id equals the question id in NIST/FinOps lenses;
    # fall back to the lone choice id otherwise.
    printf '%s' "$statusmap" | jq -r --arg q "$qid" '.[$q] // "PENDING"'
  else
    # Status precedence (consistent with recompute_parent_rollups):
    #   all applicable N/A → N/A; any FAIL → FAIL; any PENDING → PENDING;
    #   otherwise risk_to_status(risk).
    if [ "$(printf '%s' "$statusmap" | jq -r '
         if (length > 0) and (all(.[]; . == "N/A")) then "yes" else "no" end')" = "yes" ]; then
      echo "N/A"
    elif [ "$(printf '%s' "$statusmap" | jq -r '
         if any(.[]; . == "FAIL") then "yes" else "no" end')" = "yes" ]; then
      echo "FAIL"
    elif [ "$(printf '%s' "$statusmap" | jq -r '
         if any(.[]; . == "PENDING") then "yes" else "no" end')" = "yes" ]; then
      echo "PENDING"
    else
      risk_to_status "$(derive_parent_risk "$lens" "$qid" "$statusmap")"
    fi
  fi
}

# recompute_parent_rollups <report_json_path> <lens_file> [<lens_file>...]
# Builds the full parent_rollups JSON array from findings[] and the given lenses.
# For each lens question, assembles a per-question status map (choice IDs that
# exist in check-registry.json looked up in the global status map), computes
# risk/status via derive_parent_risk + derive_parent_status, and emits one rollup
# object per question to stdout as a JSON array.
# Requirements: 1.1, 1.2, 1.10, 1.12, 1.13
recompute_parent_rollups() {
  local report_json="$1"; shift
  # Remaining args are lens files
  local lens_files=("$@")

  # --- 1. Build global status map {check_id: status} from findings[] ----------
  local status_by
  status_by=$(jq -c '[.findings[]? | {key: .check_id, value: .status}] | from_entries' "$report_json")

  # --- 2. Build check-registry ID set for filtering --------------------------
  # Locate registry relative to the lens files (they share references/)
  local registry=""
  local lf
  for lf in "${lens_files[@]}"; do
    local dir
    dir=$(dirname "$lf")
    if [ -f "${dir}/check-registry.json" ]; then
      registry="${dir}/check-registry.json"
      break
    fi
  done
  # Fallback: try standard skill path
  if [ -z "$registry" ]; then
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    registry="${script_dir}/../references/check-registry.json"
  fi
  local registry_ids
  registry_ids=$(jq -c '[.checks[].check_id] | sort | unique' "$registry")

  # --- 3. Extract question index from all lenses as JSONL --------------------
  # Each line: {question_id, question_title, lens_name, pillar_name, choice_ids, has_risk_rules}
  local question_index=""
  for lf in "${lens_files[@]}"; do
    local lens_questions
    lens_questions=$(jq -c --argjson reg "$registry_ids" '
      .name as $ln |
      .pillars[]? | .name as $pn | .questions[]? |
      {
        question_id: .id,
        question_title: .title,
        lens_name: $ln,
        pillar_name: $pn,
        choice_ids: ([.choices[]?.id] | map(select(. as $c | $reg | index($c) != null))),
        has_risk_rules: ((.riskRules // []) | length > 0)
      }' "$lf")
    if [ -n "$lens_questions" ]; then
      if [ -n "$question_index" ]; then
        question_index="${question_index}
${lens_questions}"
      else
        question_index="$lens_questions"
      fi
    fi
  done

  # --- 4. Iterate questions, compute risk/status, emit rollup objects ---------
  local rollups="["
  local first="true"

  while IFS= read -r qline; do
    [ -z "$qline" ] && continue

    local qid qtitle lname pname choice_ids_json has_rules
    qid=$(printf '%s' "$qline" | jq -r '.question_id')
    qtitle=$(printf '%s' "$qline" | jq -r '.question_title')
    lname=$(printf '%s' "$qline" | jq -r '.lens_name')
    pname=$(printf '%s' "$qline" | jq -r '.pillar_name')
    choice_ids_json=$(printf '%s' "$qline" | jq -c '.choice_ids')
    has_rules=$(printf '%s' "$qline" | jq -r '.has_risk_rules')

    # Build per-question status map: only the choice IDs relevant to this question
    local q_statusmap
    q_statusmap=$(printf '%s' "$status_by" | jq -c --argjson cids "$choice_ids_json" '
      to_entries | map(select(.key as $k | $cids | index($k) != null)) | from_entries')

    # Compute risk and status
    local risk="" status=""
    if [ "$has_rules" = "true" ]; then
      # Find the lens file for this question (match by lens_name)
      local q_lens=""
      for lf in "${lens_files[@]}"; do
        local ln
        ln=$(jq -r '.name' "$lf")
        if [ "$ln" = "$lname" ]; then
          q_lens="$lf"
          break
        fi
      done
      if [ -n "$q_lens" ]; then
        # All applicable sub-checks N/A → the whole question is N/A (no risk).
        # Mirrors step-level applicable:false handling and keeps an inapplicable
        # question from rolling up to HIGH_RISK/FAIL.
        local all_na
        all_na=$(printf '%s' "$q_statusmap" | jq -r '
          if (length > 0) and (all(.[]; . == "N/A")) then "yes" else "no" end')
        if [ "$all_na" = "yes" ]; then
          status="N/A"
          risk=""
        else
          risk=$(derive_parent_risk "$q_lens" "$qid" "$q_statusmap")
          # Status is derived from the children, not purely from risk. Order:
          #   any FAIL  → FAIL    (a real failure is never hidden behind a
          #                        MEDIUM_RISK→PARTIAL mapping; FAIL outranks
          #                        an unresolved PENDING)
          #   any PENDING → PENDING (an unresolved child leaves the question
          #                        unresolved rather than PARTIAL)
          #   otherwise → risk_to_status(risk)  (a genuinely PARTIAL child on a
          #                        MEDIUM-capped question still renders PARTIAL)
          # Risk always stays as the lens computed it, so e.g. a failed BP on a
          # MEDIUM_RISK question renders "MEDIUM_RISK / FAIL".
          local has_fail has_pending
          has_fail=$(printf '%s' "$q_statusmap" | jq -r '
            if any(.[]; . == "FAIL") then "yes" else "no" end')
          has_pending=$(printf '%s' "$q_statusmap" | jq -r '
            if any(.[]; . == "PENDING") then "yes" else "no" end')
          if [ "$has_fail" = "yes" ]; then
            status="FAIL"
          elif [ "$has_pending" = "yes" ]; then
            status="PENDING"
          else
            status=$(risk_to_status "$risk")
          fi
        fi
      fi
    else
      # 1:1 case (NIST/FinOps): status of the single sub-check
      status=$(printf '%s' "$q_statusmap" | jq -r --arg q "$qid" '.[$q] // "PENDING"')
      risk=""
    fi

    # Build the sub_checks object (same as q_statusmap)
    local sub_checks="$q_statusmap"

    # Emit rollup object
    local obj
    obj=$(jq -n -c \
      --arg qid "$qid" \
      --arg qtitle "$qtitle" \
      --arg lname "$lname" \
      --arg pname "$pname" \
      --arg risk "$risk" \
      --arg status "$status" \
      --argjson sub "$sub_checks" \
      '{
        question_id: $qid,
        question_title: $qtitle,
        lens_name: $lname,
        pillar_name: $pname,
        risk: (if $risk == "" then null else $risk end),
        status: $status,
        sub_checks: $sub
      }')

    if [ "$first" = "true" ]; then
      rollups="${rollups}${obj}"
      first="false"
    else
      rollups="${rollups},${obj}"
    fi
  done <<< "$question_index"

  rollups="${rollups}]"
  printf '%s\n' "$rollups"
}

# ---------------------------------------------------------------------------
# Step → child-check status derivation (R4)
# ---------------------------------------------------------------------------

# derive_child_status <steps_json>
# Derives a child check's overall status from its per-step statuses.
# Input: JSON array of step objects with {index, status, applicable, evidence}.
# Output: one of PASS/FAIL/PARTIAL/N/A/PENDING.
#
# Logic:
#   1. Filter to steps where applicable == true AND status != "N/A"
#   2. If none remain → "N/A"
#   3. Else if any remaining step has PENDING → "PENDING"
#   4. Else if all remaining steps are PASS → "PASS"
#   5. Else if all remaining steps are FAIL → "FAIL"
#   6. Otherwise (mix of statuses) → "PARTIAL"
#
# Pure function, bash 3.2 + jq only.
# Requirements: 4.4, 4.5, 4.12
derive_child_status() {
  local steps_json="$1"
  printf '%s' "$steps_json" | jq -r '
    [.[] | select(.applicable == true and .status != "N/A")] |
    if length == 0 then "N/A"
    elif any(.status == "PENDING") then "PENDING"
    elif all(.status == "PASS") then "PASS"
    elif all(.status == "FAIL") then "FAIL"
    else "PARTIAL"
    end'
}
