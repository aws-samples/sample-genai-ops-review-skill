#!/usr/bin/env bash
# generate-report.sh — render report.md and report.html from report.json.
#
# This script is the sole renderer. It reads:
#   - ${DATA_DIR}/report.json                                 (data)
#   - ${SKILL_ROOT}/references/check-registry.json            (canonical fields)
#   - ${SKILL_ROOT}/references/report-finalizer-template.html (HTML shell)
#
# and writes:
#   - ${DATA_DIR}/report.md
#   - ${DATA_DIR}/report.html
#
# Refuses to render unless validate-report.sh passes (including coverage).
# All templating is done in jq — no markdown is parsed and no per-row bash
# loops are used (which avoids the bash `read` empty-tab-collapsing trap).
#
# Usage:
#   generate-report.sh --data-dir <dir> [--template <html>]
#
# Exit codes:
#   0  rendered successfully
#   1  argument or path error
#   2  validation failure (rendering aborted)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'USAGE_EOF'
Usage:
  generate-report.sh --data-dir <dir> [--template <html>]

Required:
  --data-dir <dir>   Review data directory (must contain report.json).

Optional:
  --template <html>  HTML template path. Defaults to
                     ${SKILL_ROOT}/references/report-finalizer-template.html.

Exit codes:
  0  rendered successfully
  1  argument or path error
  2  validation failure (rendering aborted)
USAGE_EOF
}

DATA_DIR=""
TEMPLATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)   DATA_DIR="${2:-}"; shift 2 ;;
    --data-dir=*) DATA_DIR="${1#--data-dir=}"; shift ;;
    --template)   TEMPLATE="${2:-}"; shift 2 ;;
    --template=*) TEMPLATE="${1#--template=}"; shift ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "ERROR: unknown argument: '$1'" >&2; echo "Run with --help for usage information." >&2; exit 1 ;;
  esac
done

if [ -z "$DATA_DIR" ]; then
  echo "ERROR: --data-dir is required" >&2; usage >&2; exit 1
fi
REPORT_JSON="${DATA_DIR}/report.json"
[ ! -f "$REPORT_JSON" ] && { echo "ERROR: report.json not found: ${REPORT_JSON}" >&2; exit 1; }

SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_FILE="${SKILL_ROOT}/references/check-registry.json"
[ -z "$TEMPLATE" ] && TEMPLATE="${SKILL_ROOT}/references/report-finalizer-template.html"
[ ! -f "$REGISTRY_FILE" ] && { echo "ERROR: registry not found: ${REGISTRY_FILE}" >&2; exit 1; }
[ ! -f "$TEMPLATE" ]      && { echo "ERROR: template not found: ${TEMPLATE}" >&2; exit 1; }

# Lens files — the canonical source of every check's title, display text,
# remediation guidance and documentation URL. Slurped together by the
# load_lens_index helper in _common.sh and joined into ROWS_JSON below.
LENS_FILES=(
  "${SKILL_ROOT}/references/generative-ai-lens.json"
  "${SKILL_ROOT}/references/nist-ai-rmf-lens.json"
  "${SKILL_ROOT}/references/finops-ai-lens.json"
)
EXISTING_LENSES=()
for lens_file in "${LENS_FILES[@]}"; do
  [ -f "$lens_file" ] && EXISTING_LENSES+=("$lens_file")
done

# Step 1 — full validation; refuse to render on any failure.
"${SCRIPT_DIR}/validate-report.sh" --data-dir "$DATA_DIR" --quiet || {
  rc=$?; echo "ERROR: validate-report.sh failed (exit ${rc}); refusing to render" >&2; exit 2;
}

REPORT_MD="${DATA_DIR}/report.md"
REPORT_HTML="${DATA_DIR}/report.html"

# Step 2 — build a fully-denormalized rows array via jq, joining each finding
# against the registry plus the four lens JSON files. The lens index is the
# canonical source for every check's title, display text, remediation
# guidance and documentation URL. ROWS_JSON is the single source for every
# downstream template (markdown, HTML, summaries, rollups).
ROWS_JSON=$(jq \
  --slurpfile reg "$REGISTRY_FILE" \
  --slurpfile lenses_arr <(jq -s '.' "${EXISTING_LENSES[@]}") '
  ($reg[0].checks | map({key: .check_id, value: .}) | from_entries) as $byId
  | (
      [ $lenses_arr[0] | to_entries[] | .key as $li | .value as $lens
        | $lens.pillars | to_entries[]? | .key as $pi | .value as $p
        | $p.questions | to_entries[]? | .key as $qi | .value as $q
        | $q.choices[]? as $c
        | select(($c.id // "") | endswith("_no") | not)
        | { key: ($c.id // ""), value: {
              lens_name:            ($lens.name // ""),
              lens_order:           $li,
              pillar_id:            ($p.id // ""),
              pillar_name:          ($p.name // ""),
              pillar_order:         $pi,
              question_id:          ($q.id // ""),
              question_title:       (if ($q.short_title // "") != "" then ($q.short_title + ": " + $q.title) else ($q.title // "") end),
              question_order:       $qi,
              question_description: ($q.description // ""),
              title:                ($c.title // ""),
              display_text:         (($c.helpfulResource.displayText // "")),
              url:                  (($c.helpfulResource.url // "")),
              improvement_text:     (($c.improvementPlan.displayText // "")),
              improvement_url:      (($c.improvementPlan.url // ""))
            }
          }
      ] | from_entries
    ) as $byLens
  | .findings | map(. as $f | ($byId[$f.check_id] // {}) as $r | ($byLens[$f.check_id] // {}) as $l |
      {
        check_id:   $f.check_id,
        framework:  ($r.canonical_owner // "" | split(":")[0]),
        category:   ($r.category // ($r.canonical_owner // ":" | split(":")[1] // "")),
        title:      ($l.title // $r.title // ""),
        display_text: ($l.display_text // ""),
        url:        ($l.url // ""),
        improvement_text: ($l.improvement_text // ""),
        improvement_url:  ($l.improvement_url // ""),
        question_id: ($l.question_id // ""),
        question_title: ($l.question_title // ""),
        question_description: ($l.question_description // ""),
        lens_name:  ($l.lens_name // ""),
        lens_order: ($l.lens_order // 99),
        pillar_name: ($l.pillar_name // ""),
        pillar_order: ($l.pillar_order // 99),
        question_order: ($l.question_order // 99),
        severity:   ($r.severity // "MEDIUM"),
        status:     $f.status,
        method:     ($f.method // (if $f.status == "PENDING" then "needs-input" else "auto" end)),
        source:     ($f.source // ""),
        maturity:   ($f.maturity // ""),
        finding:    ($f.finding // ""),
        remediation:($f.remediation // ""),
        doc_url:    ($f.doc_url // ($l.url // "")),
        question:   ($f.question // ""),
        why_it_matters: ($f.why_it_matters // ""),
        reason:     ($f.reason // ""),
        steps:      ($f.steps // []),
        pillars:    ($r.pillars // [])
      })
  | sort_by(.lens_order, .pillar_order, .question_order, .check_id)
' "$REPORT_JSON")

PILLARS_JSON=$(jq '.pillars' "$REGISTRY_FILE")

# Per-question parent risk/status is NOT recomputed here. It is read from
# report.json.parent_rollups — the deterministic rollup derived in
# merge-findings.sh and verified by validate-report.sh — and rendered as-is
# by build_md / build_html_body below.

# ---------------------------------------------------------------------------
# build_md — jq-only markdown templating. No bash read loops.
# ---------------------------------------------------------------------------
build_md() {
  jq -nr \
    --slurpfile rep "$REPORT_JSON" \
    --argjson rows "$ROWS_JSON" \
    --argjson pillars "$PILLARS_JSON" '
def md_finding($r):
  ($r.severity) as $sev
  | (if $r.status == "N/A" then
       (if $r.source != "" then "[\($r.source)]" else "" end)
     else
       "[\($r.method)]" + (if $r.source != "" then " [\($r.source)]" else "" end)
     end) as $tags
  | "#### [\($r.framework):\($r.category)] [\($r.check_id)] — \($r.title)"
    + (if $tags != "" then " \($tags)" else "" end)
    + " — \($r.status)\n\n"
  + "**Pillars:** \(($r.pillars // []) | join(", "))\n"
  + (if $r.status != "N/A" then "**Severity:** \($sev)\n" else "" end)
  + (if $r.maturity != "" then "**Maturity:** \($r.maturity)\n" else "" end)
  + (if ($r.display_text // "") != "" then "\n**About:** \($r.display_text)\n" else "" end)
  + (
      # Documentation link — emitted on every finding regardless of status.
      (if ($r.url // "") != "" then "\n- Documentation: \($r.url)\n"
       elif ($r.doc_url // "") != "" then "\n- Documentation: \($r.doc_url)\n"
       else "" end)) as $doc
  | (if $r.status == "PASS" then
       "\n**Finding:** \($r.finding)\n" + $doc
     elif $r.status == "FAIL" or $r.status == "PARTIAL" then
       "\n**Finding:** \($r.finding)\n\n**Remediation:**\n\n\($r.remediation)\n"
       + (if (($r.improvement_text // "") != "") and ($r.improvement_text != $r.remediation) then
           "\n**Authoritative guidance:** \($r.improvement_text)\n" else "" end)
       + $doc
     elif $r.status == "PENDING" then
       (if (($r.finding // "") != "") then
         "\n**Finding:** \($r.finding)\n"
         + (if (($r.remediation // "") != "") then "\n**Remediation:**\n\n\($r.remediation)\n" else "" end)
         + (( [ ($r.steps // [])[] | select(.status == "PENDING" and .applicable == true) ])
             | if length == 0 then ""
               elif length == 1 then "\n**Reason pending:** Step \(.[0].index) requires human input: \(.[0].evidence // "cannot be verified automatically")\n"
               else "\n**Reason pending:** Steps \(map(.index | tostring) | join(", ")) require human input: \(map(.evidence // "unverifiable") | join("; "))\n"
               end
           )
         + "\n**Question:** \($r.question)\n"
         + (if $r.why_it_matters != "" then "\n**Why it matters:** \($r.why_it_matters)\n" else "" end)
         + $doc
       else
         "\n**Question:** \($r.question)\n"
         + (if $r.why_it_matters != "" then "\n**Why it matters:** \($r.why_it_matters)\n" else "" end)
         + $doc
       end)
     elif $r.status == "N/A" then
       "**Reason:** \($r.reason)\n" + $doc
     else "" end);

def pillar_subcat_section:
  def status_order($s):
    if $s == "FAIL" then 0
    elif $s == "PARTIAL" then 1
    elif $s == "PENDING" then 2
    elif $s == "PASS" then 3
    elif $s == "N/A" then 4
    else 5 end;
  def severity_order($s):
    if $s == "CRITICAL" then 0
    elif $s == "HIGH" then 1
    elif $s == "MEDIUM" then 2
    elif $s == "LOW" then 3
    else 4 end;
  # Parent rollup lookup keyed by question_id, read straight from the
  # verified report.json.parent_rollups (never recomputed here).
  ($rep[0].parent_rollups // [] | map({key: .question_id, value: .}) | from_entries) as $rollupBy
  | reduce .[] as $r ({};
      (($r.lens_name // "Other") + "\u0001" + ($r.pillar_name // $r.category) + "\u0001" + ($r.question_title // $r.category)) as $key
      | .[$key] += [$r])
  | to_entries
  | sort_by((.value[0].lens_order // 99), (.value[0].pillar_order // 99), (.value[0].question_order // 99))
  | reduce .[] as $entry ({last_lens: "", last_pillar: "", out: ""};
      ($entry.key | split("\u0001")) as $pc
      | ($entry.value | sort_by(severity_order(.severity), status_order(.status), .check_id)) as $sorted_vals
      | ($rollupBy[$entry.value[0].question_id // ""]) as $roll
      | (if ($roll != null) and (($roll.risk // null) != null)
           then "**Parent risk:** \($roll.risk) — **Status:** \($roll.status)\n\n"
           else "" end) as $risk_line
      | (if .last_lens != $pc[0]
           then "\(.out)\n### \($pc[0])\n\n#### \($pc[1])\n\n##### \($pc[2])\n\n"
         elif .last_pillar != $pc[1]
           then "\(.out)\n#### \($pc[1])\n\n##### \($pc[2])\n\n"
         else "\(.out)\n##### \($pc[2])\n\n" end) as $out2
      | { last_lens: $pc[0], last_pillar: $pc[1],
          out: ($out2 + $risk_line + ($sorted_vals | map(md_finding(.)) | join("\n"))) }
    )
  | .out;

def stats_by_status:
  reduce .[] as $r ({};
    .[$r.status] += 1)
  | (.PASS // 0) as $p | (.FAIL // 0) as $f | (.PARTIAL // 0) as $pa
  | (.["N/A"] // 0) as $n | (.PENDING // 0) as $pe
  | { pass: $p, fail: $f, partial: $pa, na: $n, pending: $pe,
      total: ($p + $f + $pa + $n + $pe) };

def summary_table:
  # Group by lens+pillar, preserving lens/pillar order from the lens JSON
  reduce .[] as $r ({};
    (($r.lens_name // "Other") + "\u0001" + ($r.pillar_name // $r.category)) as $key
    | .[$key] += [$r]
    | .[$key + "\u0002order"] = (if .[$key + "\u0002order"] then .[$key + "\u0002order"] else {l: $r.lens_order, p: $r.pillar_order} end))
  | to_entries
  | map(select(.key | contains("\u0002order") | not))
  | sort_by((.value[0].lens_order // 99), (.value[0].pillar_order // 99))
  | map(
      (.key | split("\u0001")) as $parts
      | (.value | stats_by_status) as $s
      | ($parts[0] | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $lens_anchor
      | (($parts[0] + "-" + $parts[1]) | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $pillar_anchor
      | "| [\($parts[0])](#\($lens_anchor)) | [\($parts[1])](#\($pillar_anchor)) | \($s.total) | \($s.pass) | \($s.fail) | \($s.partial) | \($s.na) | \($s.pending) |"
    ) | join("\n");

def remediation_section($rows; $sev; $label):
  "### \($label)\n"
  + (
      ($rows | map(select(.severity == $sev and (.status == "FAIL" or .status == "PARTIAL"))))
      | if length == 0 then "*No \($sev) findings.*\n"
        else (to_entries | map("\(.key + 1). **[\(.value.framework):\(.value.category)]** `\(.value.check_id)` — \(.value.title) (\(.value.status))") | join("\n") + "\n")
        end
    );

($rep[0]) as $report
| ($report.metadata) as $m
| (
    "# AWS AIO2 Multi-Framework Review — \($m.solution_name // "")\n\n"
    + "| Field | Value |\n|-------|-------|\n"
    + "| Solution | `\($m.solution_name // "")` |\n"
    + "| Region | `\($m.region // "")` |\n"
    + "| Account | `\($m.account_id // "")` |\n"
    + "| AWS Profile | \($m.profile // "default") |\n"
    + "| Identity | `\($m.identity_arn // "")` |\n"
    + "| Input Type | \($m.input_type // "") |\n"
    + "| Resources Discovered | \($m.resources_summary // "") |\n"
    + "| Model(s) | `\(($m.models // []) | join(", "))` |\n"
    + "| Review Date | \($m.review_date // "") |\n"
    + "| Review Scope | \($m.review_scope // "") |\n"
    + "| Frameworks | \(($m.frameworks // []) | join(", ")) |\n\n---\n\n"
  ),
  "## Executive Summary\n\n",
  ($report.executive_summary.prose // ""),
  "\n\n---\n\n## Assessment Summary\n\n",
  "| Lens | Pillar | Total | PASS | FAIL | PARTIAL | N/A | PENDING |\n|------|--------|:---:|:---:|:---:|:---:|:---:|:---:|\n",
  ($rows | summary_table),
  "\n",
  ($rows | stats_by_status as $t |
    "| **Total** | | **\($t.total)** | **\($t.pass)** | **\($t.fail)** | **\($t.partial)** | **\($t.na)** | **\($t.pending)** |"),
  "\n\n---\n\n## Detailed Findings\n\n",
  ($rows | pillar_subcat_section),  "\n\n---\n\n## Remediation Priority\n\n",
  remediation_section($rows; "CRITICAL"; "Immediate (CRITICAL)"), "\n",
  remediation_section($rows; "HIGH";     "Short-term (HIGH)"),    "\n",
  remediation_section($rows; "MEDIUM";   "Medium-term (MEDIUM)"), "\n",
  remediation_section($rows; "LOW";      "Long-term (LOW)"),      "\n",
  "\n---\n\n## Checks Requiring Human Input\n\n",
  (
    ($rows | map(select(.status == "PENDING"))) as $pending
    | if ($pending | length) == 0 then "All checks were assessed — no pending items.\n"
      else
        "| Framework | Category | Check ID | Question | Severity |\n|-----------|----------|----------|----------|----------|\n"
        + ($pending | map("| \(.framework) | \(.category) | `\(.check_id)` | \(.question) | \(.severity) |") | join("\n")) + "\n"
      end
  ),
  "\n---\n\n*Report generated by AWS AIO2 Multi-Framework Review*\n"
  ' > "$REPORT_MD"

  log_info "generate-report: wrote ${REPORT_MD}"
}

# ---------------------------------------------------------------------------
# build_html_body — emits the body content (between BODY_CONTENT markers).
# ---------------------------------------------------------------------------
build_html_body() {
  jq -nr \
    --slurpfile rep "$REPORT_JSON" \
    --argjson rows "$ROWS_JSON" '
def esc:
  if type == "string" then
    gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
  else . end;

def lc: ascii_downcase;

def card_class($r):
  if $r.status == "PASS" then "status-pass"
  elif $r.status == "N/A" then "status-na"
  elif $r.status == "PENDING" then "status-pending"
  else "severity-" + ($r.severity | lc)
  end;

def status_badge_class($r):
  if $r.status == "N/A" then "badge-na" else "badge-" + ($r.status | lc | gsub("/"; "-")) end;

def severity_badge_class($r):
  "badge-" + ($r.severity | lc);

# Documentation link block — emitted on every card regardless of status.
# Prefers the canonical lens URL, falling back to the finding doc_url.
def doc_link($r):
  (if (($r.url // "") != "")
     then "    <ul><li>Documentation: <a href=\"\($r.url | esc)\">\($r.url | esc)</a></li></ul>\n"
   elif (($r.doc_url // "") != "")
     then "    <ul><li>Documentation: <a href=\"\($r.doc_url | esc)\">\($r.doc_url | esc)</a></li></ul>\n"
   else "" end);

def html_card($r):
  # When a question maps to a single check the card title (and, for PENDING,
  # the Question line) just restate the question heading rendered above the
  # card. Detect that duplication and suppress the in-card copy.
  ((($r.question_title // "") != "") and ($r.title == $r.question_title)) as $title_dup
  | ((($r.question_title // "") != "") and ($r.question == $r.question_title)) as $question_dup
  | "<div class=\"finding-card \(card_class($r))\">\n"
  + "  <div class=\"finding-header\">\n"
  + "    <span class=\"finding-id\">\($r.check_id | esc)</span>\n"
  + (if $title_dup then "" else "    <span class=\"finding-title\">— \($r.title | esc)</span>\n" end)
  + "    <span class=\"badge \(status_badge_class($r))\">\($r.status)</span>\n"
  + (if $r.status != "N/A" and ($r.status != "PENDING" or (($r.finding // "") != ""))
       then "    <span class=\"badge \(severity_badge_class($r))\">\($r.severity)</span>\n"
       else "" end)
  + "  </div>\n"
  + "  <div class=\"finding-body\">\n"
  + (if (($r.display_text // "") != "")
       then "    <p class=\"finding-about\"><em>\($r.display_text | esc)</em></p>\n"
       else "" end)
  + (if $r.status == "PASS" then
       "    <p><strong>Finding:</strong> \($r.finding | esc)</p>\n"
       + doc_link($r)
     elif $r.status == "FAIL" or $r.status == "PARTIAL" then
       "    <p><strong>Finding:</strong> \($r.finding | esc)</p>\n"
       + "    <div class=\"remediation-label\">Remediation</div>\n"
       + "    <p>\($r.remediation | esc)</p>\n"
       + (if (($r.improvement_text // "") != "") and ($r.improvement_text != $r.remediation) then
           "    <p><strong>Authoritative guidance:</strong> \($r.improvement_text | esc)</p>\n"
          else "" end)
       + doc_link($r)
     elif $r.status == "PENDING" then
       (if (($r.finding // "") != "") then
         "    <p><strong>Finding:</strong> \($r.finding | esc)</p>\n"
         + (if (($r.remediation // "") != "") then
             "    <div class=\"remediation-label\">Remediation</div>\n"
             + "    <p>\($r.remediation | esc)</p>\n"
           else "" end)
         + (( [ ($r.steps // [])[] | select(.status == "PENDING" and .applicable == true) ])
             | if length == 0 then ""
               elif length == 1 then "    <p><strong>Reason pending:</strong> Step \(.[0].index) requires human input: \(.[0].evidence // "cannot be verified automatically" | esc)</p>\n"
               else "    <p><strong>Reason pending:</strong> Steps \(map(.index | tostring) | join(", ")) require human input: \(map(.evidence // "unverifiable" | esc) | join("; "))</p>\n"
               end
           )
         + (if $question_dup then "" else "    <p><strong>Question:</strong> \($r.question | esc)</p>\n" end)
         + (if (($r.why_it_matters // "") != "") then "    <p><strong>Why it matters:</strong> \($r.why_it_matters | esc)</p>\n" else "" end)
         + doc_link($r)
       else
         (if $question_dup then "" else "    <p><strong>Question:</strong> \($r.question | esc)</p>\n" end)
         + (if (($r.why_it_matters // "") != "") then "    <p><strong>Why it matters:</strong> \($r.why_it_matters | esc)</p>\n" else "" end)
         + doc_link($r)
       end)
     elif $r.status == "N/A" then
       "    <p><strong>Reason:</strong> \($r.reason | esc)</p>\n"
       + doc_link($r)
     else "" end)
  + "  </div>\n</div>\n";

def stats:
  reduce .[] as $r ({};
    .[$r.status] += 1)
  | (.PASS // 0) as $p | (.FAIL // 0) as $f | (.PARTIAL // 0) as $pa
  | (.["N/A"] // 0) as $n | (.PENDING // 0) as $pe
  | { pass: $p, fail: $f, partial: $pa, na: $n, pending: $pe,
      total: ($p + $f + $pa + $n + $pe) };

def pct($a; $tot):
  if $tot == 0 then "0" else (($a * 100 / $tot) | floor | tostring) end;

($rep[0]) as $report
| ($report.metadata) as $m
| ($rows | stats) as $st

# ----- Review Metadata
| "<div class=\"section\">\n  <h2>Review Metadata</h2>\n  <table class=\"meta-table\">\n"
  + "    <tr><th>Solution</th><td><code>\($m.solution_name // "" | esc)</code></td></tr>\n"
  + "    <tr><th>Region</th><td><code>\($m.region // "" | esc)</code></td></tr>\n"
  + "    <tr><th>Account</th><td><code>\($m.account_id // "" | esc)</code></td></tr>\n"
  + "    <tr><th>AWS Profile</th><td>\($m.profile // "default" | esc)</td></tr>\n"
  + "    <tr><th>Identity</th><td><code>\($m.identity_arn // "" | esc)</code></td></tr>\n"
  + "    <tr><th>Input Type</th><td>\($m.input_type // "" | esc)</td></tr>\n"
  + "    <tr><th>Resources</th><td>\($m.resources_summary // "" | esc)</td></tr>\n"
  + "    <tr><th>Models</th><td><code>\(($m.models // []) | join(", ") | esc)</code></td></tr>\n"
  + "    <tr><th>Review Date</th><td>\($m.review_date // "" | esc)</td></tr>\n"
  + "    <tr><th>Review Scope</th><td>\($m.review_scope // "" | esc)</td></tr>\n"
  + "    <tr><th>Frameworks</th><td>\(($m.frameworks // []) | join(", ") | esc)</td></tr>\n"
  + "  </table>\n</div>\n",

# ----- Executive Summary
  "<div class=\"section\">\n  <h2>Executive Summary</h2>\n  <div>",
  ($report.executive_summary.prose // ""
    | split("\n\n")
    | map("<p>" + (. | esc | gsub("\n"; "<br>")) + "</p>")
    | join("")),
  "</div>\n  <div class=\"score-bar-container\">\n    <div class=\"score-bar\">\n",
  "      <div class=\"seg-pass\" style=\"width:\(pct($st.pass; $st.total))%\">\($st.pass)</div>\n",
  "      <div class=\"seg-partial\" style=\"width:\(pct($st.partial; $st.total))%\">\($st.partial)</div>\n",
  "      <div class=\"seg-fail\" style=\"width:\(pct($st.fail; $st.total))%\">\($st.fail)</div>\n",
  "      <div class=\"seg-na\" style=\"width:\(pct($st.na; $st.total))%\">\($st.na)</div>\n",
  "      <div class=\"seg-pending\" style=\"width:\(pct($st.pending; $st.total))%\">\($st.pending)</div>\n",
  "    </div>\n    <div class=\"score-legend\">\n",
  "      <span class=\"leg-pass\">Pass (\($st.pass))</span>\n",
  "      <span class=\"leg-partial\">Partial (\($st.partial))</span>\n",
  "      <span class=\"leg-fail\">Fail (\($st.fail))</span>\n",
  "      <span class=\"leg-na\">N/A (\($st.na))</span>\n",
  "      <span class=\"leg-pending\">Pending (\($st.pending))</span>\n",
  "    </div>\n  </div>\n</div>\n",

# ----- Summary table (Lens → Pillar)
  "<div class=\"section\">\n  <h2>Assessment Summary</h2>\n  <table class=\"summary-table\">\n",
  "    <tr><th>Lens</th><th>Pillar</th><th>Total</th><th>PASS</th><th>FAIL</th><th>PARTIAL</th><th>N/A</th><th>PENDING</th></tr>\n",
  (($rows | reduce .[] as $r ({};
      (($r.lens_name // "Other") + "\u0001" + ($r.pillar_name // $r.category)) as $key
      | .[$key] += [$r]))
    | to_entries
    | sort_by((.value[0].lens_order // 99), (.value[0].pillar_order // 99))
    | map(
        (.key | split("\u0001")) as $parts
        | (.value | stats) as $s
        | ($parts[0] | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $lens_anchor
        | (($parts[0] + "-" + $parts[1]) | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $pillar_anchor
        | "    <tr><td><a href=\"#\($lens_anchor)\">\($parts[0] | esc)</a></td><td><a href=\"#\($pillar_anchor)\">\($parts[1] | esc)</a></td><td>\($s.total)</td><td class=\"pass-cell\">\($s.pass)</td><td class=\"fail-cell\">\($s.fail)</td><td class=\"partial-cell\">\($s.partial)</td><td class=\"na-cell\">\($s.na)</td><td class=\"pending-cell\">\($s.pending)</td></tr>"
      ) | join("\n") + "\n"),
  "    <tr><td><strong>Total</strong></td><td></td><td><strong>\($st.total)</strong></td><td class=\"pass-cell\"><strong>\($st.pass)</strong></td><td class=\"fail-cell\"><strong>\($st.fail)</strong></td><td class=\"partial-cell\"><strong>\($st.partial)</strong></td><td class=\"na-cell\"><strong>\($st.na)</strong></td><td class=\"pending-cell\"><strong>\($st.pending)</strong></td></tr>\n",
  "  </table>\n</div>\n",

# ----- Detailed Findings — grouped by Lens → Pillar → Question, ordered by Severity → Status
  "<div class=\"section\">\n  <h2>Detailed Findings</h2>\n",
  (
    def status_ord: if . == "FAIL" then 0 elif . == "PARTIAL" then 1 elif . == "PENDING" then 2 elif . == "PASS" then 3 elif . == "N/A" then 4 else 5 end;
    def sev_ord: if . == "CRITICAL" then 0 elif . == "HIGH" then 1 elif . == "MEDIUM" then 2 elif . == "LOW" then 3 else 4 end;
    # Parent risk/status badge pair, read from the verified parent_rollups
    # (never recomputed). Reuses the existing badge CSS classes: risk maps
    # to its status-equivalent colour (HIGH→fail, MEDIUM→partial, NO→pass).
    def parent_badges($roll):
      if ($roll == null) or (($roll.risk // null) == null) then ""
      else
        (if $roll.risk == "HIGH_RISK" then "badge-fail"
         elif $roll.risk == "MEDIUM_RISK" then "badge-partial"
         elif $roll.risk == "NO_RISK" then "badge-pass"
         else "badge-na" end) as $rcls
        | (if $roll.status == "N/A" then "badge-na"
           else "badge-" + ($roll.status | ascii_downcase | gsub("/"; "-")) end) as $scls
        | " <span class=\"badge \($rcls)\">\($roll.risk | esc)</span>"
          + " <span class=\"badge \($scls)\">\($roll.status | esc)</span>"
      end;
    ($rep[0].parent_rollups // [] | map({key: .question_id, value: .}) | from_entries) as $rollupBy
    | ($rows | reduce .[] as $r ({};
        (($r.lens_name // "Other") + "\u0001" + ($r.pillar_name // $r.category) + "\u0001" + ($r.question_title // $r.category)) as $key
        | .[$key] += [$r]))
    | to_entries
    | sort_by((.value[0].lens_order // 99), (.value[0].pillar_order // 99), (.value[0].question_order // 99))
    | reduce .[] as $entry ({last_lens: "", last_pillar: "", out: ""};
        ($entry.key | split("\u0001")) as $parts
        | ($parts[0] | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $lens_anchor
        | (($parts[0] + "-" + $parts[1]) | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $pillar_anchor
        | ($parts[2] | gsub("[^a-zA-Z0-9]"; "-") | ascii_downcase) as $q_anchor
        | parent_badges($rollupBy[$entry.value[0].question_id // ""]) as $q_badges
        | ($entry.value | sort_by((.severity | sev_ord), (.status | status_ord), .check_id)) as $sorted
        | (if .last_lens != $parts[0]
             then .out + "<div class=\"pillar-heading\" id=\"\($lens_anchor)\"><h2>\($parts[0] | esc)</h2></div>\n<div class=\"topic-heading\" id=\"\($pillar_anchor)\"><h3>\($parts[1] | esc)</h3></div>\n<h4 id=\"\($q_anchor)\">\($parts[2] | esc)\($q_badges)</h4>\n"
           elif .last_pillar != $parts[1]
             then .out + "<div class=\"topic-heading\" id=\"\($pillar_anchor)\"><h3>\($parts[1] | esc)</h3></div>\n<h4 id=\"\($q_anchor)\">\($parts[2] | esc)\($q_badges)</h4>\n"
           else .out + "<h4 id=\"\($q_anchor)\">\($parts[2] | esc)\($q_badges)</h4>\n"
           end) as $header
        | { last_lens: $parts[0], last_pillar: $parts[1],
            out: ($header + ($sorted | map(html_card(.)) | join(""))) }
      )
    | .out
  ),
  "</div>\n",

# ----- Pending Checks table
  "<div class=\"section\">\n  <h2>Checks Requiring Human Input</h2>\n",
  (($rows | map(select(.status == "PENDING")) | sort_by(.framework, .category, .check_id)) as $pend
   | if ($pend | length) == 0 then "  <p>All checks were assessed — no pending items.</p>\n"
     else
       "  <table class=\"summary-table\">\n"
       + "    <tr><th>Framework</th><th>Category</th><th>Check ID</th><th>Question</th><th>Severity</th></tr>\n"
       + ($pend | map("    <tr><td>\(.framework)</td><td>\(.category)</td><td><code>\(.check_id)</code></td><td>\(.question | esc)</td><td>\(.severity)</td></tr>") | join("\n"))
       + "\n  </table>\n"
     end),
  "</div>\n",

# ----- Remediation Priority
  "<div class=\"section\">\n  <h2>Remediation Priority</h2>\n",
  (
    [
      {sev:"CRITICAL", label:"Immediate (CRITICAL)", cls:"critical-num"},
      {sev:"HIGH",     label:"Short-term (HIGH)",    cls:"high-num"},
      {sev:"MEDIUM",   label:"Medium-term (MEDIUM)", cls:"medium-num"},
      {sev:"LOW",      label:"Long-term (LOW)",      cls:"low-num"}
    ]
    | map(. as $g
        | ($rows | map(select(.severity == $g.sev and (.status == "FAIL" or .status == "PARTIAL"))) | sort_by(.framework, .category, .check_id)) as $items
        | "  <div class=\"priority-group\"><h3>\($g.label)</h3>\n"
          + (if ($items | length) == 0 then "    <p><em>No \($g.sev) findings.</em></p>\n"
             else "    <ol class=\"priority-list\">\n"
                  + ($items | to_entries | map(
                      "      <li><span class=\"priority-num \($g.cls)\">\(.key + 1)</span><strong>[\(.value.framework):\(.value.category)]</strong> <code>\(.value.check_id | esc)</code> — \(.value.title | esc) (\(.value.status))</li>"
                    ) | join("\n")) + "\n"
                  + "    </ol>\n"
             end)
          + "  </div>\n"
      ) | join("")
  ),
  "</div>\n"
'
}

# ---------------------------------------------------------------------------
# Splice the body into the template, preserving head + footer.
# Substitutes header/title/footer placeholders ([SOLUTION_NAME], [REGION],
# [DATE], etc.) on every template line that is not part of the body region.
# Body content (between BODY_CONTENT markers) is fully rendered HTML from
# build_html_body and is NOT passed through substitution.
# ---------------------------------------------------------------------------
build_html() {
  local body_tmp; body_tmp=$(mktemp)
  build_html_body > "$body_tmp"

  # Pull header/footer values from report.json metadata.
  local meta_solution meta_region meta_account meta_input_type \
        meta_resources meta_models meta_scope meta_frameworks meta_date
  meta_solution=$(jq -r '.metadata.solution_name // ""'        "$REPORT_JSON")
  meta_region=$(jq   -r '.metadata.region // ""'               "$REPORT_JSON")
  meta_account=$(jq  -r '.metadata.account_id // ""'           "$REPORT_JSON")
  meta_input_type=$(jq -r '.metadata.input_type // ""'         "$REPORT_JSON")
  meta_resources=$(jq  -r '.metadata.resources_summary // ""'  "$REPORT_JSON")
  meta_models=$(jq     -r '.metadata.models | join(", ")'      "$REPORT_JSON")
  meta_scope=$(jq      -r '.metadata.review_scope // ""'       "$REPORT_JSON")
  meta_frameworks=$(jq -r '.metadata.frameworks | join(", ")'  "$REPORT_JSON")
  meta_date=$(jq       -r '.metadata.review_date // ""'        "$REPORT_JSON")

  awk -v body_file="$body_tmp" \
      -v solution="$meta_solution" \
      -v region="$meta_region" \
      -v account="$meta_account" \
      -v input_type="$meta_input_type" \
      -v resources="$meta_resources" \
      -v models="$meta_models" \
      -v scope="$meta_scope" \
      -v frameworks="$meta_frameworks" \
      -v review_date="$meta_date" '
    function repl(s) {
      gsub(/\[SOLUTION_NAME\]/, solution, s)
      gsub(/\[SOLUTION_IDENTIFIER\]/, solution, s)
      gsub(/\[REGION\]/, region, s)
      gsub(/\[ACCOUNT_ID\]/, account, s)
      gsub(/\[Agent ARN \/ CloudFormation Stack \/ AppRegistry Application \/ Resource Group \/ Code Workspace\]/, input_type, s)
      gsub(/\[RESOURCE_SUMMARY\]/, resources, s)
      gsub(/\[MODEL_IDS\]/, models, s)
      gsub(/\[Code Review \/ Cloud Review \/ Full Review\]/, scope, s)
      gsub(/\[WA \/ NIST \/ FinOps \/ All\]/, frameworks, s)
      gsub(/\[DATE\]/, review_date, s)
      return s
    }
    /<!-- BODY_CONTENT_START -->/ {
      print repl($0)
      while ((getline line < body_file) > 0) print line
      close(body_file)
      in_body = 1
      next
    }
    /<!-- BODY_CONTENT_END -->/ { in_body = 0; print repl($0); next }
    !in_body { print repl($0) }
  ' "$TEMPLATE" > "$REPORT_HTML"

  rm -f "$body_tmp"
  log_info "generate-report: wrote ${REPORT_HTML}"
}

build_md
build_html

exit 0
