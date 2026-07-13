#!/usr/bin/env bash
# audit-readonly.sh — Verify all AWS CLI invocations in scripts use read-only operations.
#
# Scans all *.sh files in the scripts/ directory and checks that every
# `aws <service> <operation>` call uses an allowed read-only prefix.
#
# Allowed prefixes: get-, list-, describe-, head-, lookup-, select-
#
# Exit 0 if all operations are read-only; exit 1 with diagnostics on stderr.
# Validates: Requirements 8.1, 8.2, 8.3

source "$(dirname "$0")/_common.sh"

# ---------------------------------------------------------------------------
# Allowed read-only operation prefixes
# ---------------------------------------------------------------------------
READONLY_PREFIXES="^(get-|list-|describe-|head-|lookup-|select-)"

# ---------------------------------------------------------------------------
# Main audit logic
# ---------------------------------------------------------------------------
offenders=0

# Scan all *.sh files under SCRIPT_DIR for AWS CLI invocations
while IFS= read -r line; do
    # line format from grep -nH: file:lineno:content
    file="$(echo "$line" | cut -d: -f1)"
    lineno="$(echo "$line" | cut -d: -f2)"
    content="$(echo "$line" | cut -d: -f3-)"

    # Skip comment lines (optional whitespace followed by #)
    if echo "$content" | grep -qE '^[[:space:]]*#'; then
        continue
    fi

    # Skip lines that look like they're inside strings/heredocs
    # (preceded by quote characters: single quote, double quote, or backtick)
    if echo "$content" | grep -qE "^[[:space:]]*[\"'\`]"; then
        continue
    fi

    # Extract the operation token (third word after 'aws')
    operation="$(echo "$content" | sed -n 's/.*aws[[:space:]][[:space:]]*[a-z0-9-][a-z0-9-]*[[:space:]][[:space:]]*\([a-z][a-z0-9-]*\).*/\1/p' | head -1)"

    if [ -z "$operation" ]; then
        continue
    fi

    # Check if operation starts with an allowed prefix
    if ! echo "$operation" | grep -qE "$READONLY_PREFIXES"; then
        echo "${file}:${lineno}: ${operation}" >&2
        offenders=$((offenders + 1))
    fi
done <<EOF
$(grep -nHE '\baws[[:space:]]+[a-z0-9-]+[[:space:]]+[a-z][a-z0-9-]*' "${SCRIPT_DIR}"/*.sh 2>/dev/null || true)
EOF

if [ "$offenders" -gt 0 ]; then
    exit 1
fi

exit 0
