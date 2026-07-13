# _pillar_map_parse.awk — parse pillar-to-check-map.md
# Usage: awk -f _pillar_map_parse.awk pillar-to-check-map.md
# Output: CHECK_ID\tpillar_id1,pillar_id2,...
# Exits non-zero if any pillar token is outside {1,2,3,4,5,6}.

BEGIN {
    FS = "|"
    valid["1"] = 1; valid["2"] = 1; valid["3"] = 1
    valid["4"] = 1; valid["5"] = 1; valid["6"] = 1
    err = 0
}

# Skip non-table lines
!/^\|/ { next }

# Skip separator lines (e.g. |---|---|---|---|)
/^\|[[:space:]]*[-:]+[[:space:]]*\|/ { next }

# Skip header lines containing "Check ID" or column header markers
/Check ID/ { next }
/^[|][[:space:]]*#[[:space:]]*[|]/ { next }

{
    # Column 1 = empty (before first |), column 2 = Check ID, column 4 = Pillar
    # Fields: $1="" $2=CheckID $3=Source $4=Pillar $5=Description
    check_id = $2
    pillar_raw = $4

    # Trim whitespace from check_id
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", check_id)

    # Skip if check_id is empty
    if (check_id == "") next

    # Skip the top-level pillar definition table (has # column)
    # That table uses numeric first column like "1", "2", etc. with bold pillar names
    if (check_id ~ /^[0-9]+$/) next

    # Parse pillar_raw: "Pillar 1, Pillar 5" -> "1,5"
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", pillar_raw)

    # Split on comma
    n = split(pillar_raw, parts, ",")
    pillar_ids = ""
    for (i = 1; i <= n; i++) {
        p = parts[i]
        # Remove "Pillar" prefix and whitespace
        gsub(/[Pp]illar/, "", p)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)

        if (p == "") continue

        # Validate
        if (!(p in valid)) {
            print "ERROR: invalid pillar \"" p "\" for check " check_id > "/dev/stderr"
            err = 1
        }

        if (pillar_ids == "") {
            pillar_ids = p
        } else {
            pillar_ids = pillar_ids "," p
        }
    }

    if (pillar_ids != "") {
        print check_id "\t" pillar_ids
    }
}

END {
    if (err) exit 1
}
