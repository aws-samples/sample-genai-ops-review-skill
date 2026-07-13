#!/usr/bin/env bash
# build-lenses.sh — regenerate the NIST and FinOps lens JSON files from
# their authoritative YAML sources. Each lens follows the same grammar as
# the upstream AWS Well-Architected GenAI Lens JSON (pillars → questions →
# choices, with helpfulResource and improvementPlan per choice).
#
# Inputs:
#   ${SKILL_ROOT}/references/nist-ai-rmf-checks.yaml
#   ${SKILL_ROOT}/references/finops-ai-checks.yaml
#
# Outputs:
#   ${SKILL_ROOT}/references/nist-ai-rmf-lens.json
#   ${SKILL_ROOT}/references/finops-ai-lens.json
#
# This is a maintainer tool. Run it whenever the YAML sources change.
# Usage:
#   build-lenses.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF_DIR="${SKILL_ROOT}/references"

# yaml_to_jsonl <yaml_path> <id_field> <category_field> <subcategory_field>
# Converts the simple list-of-objects YAML used by NIST and FinOps into
# JSONL records with: id, function_or_domain, category, subcategory_or_capability,
# description, severity, interactive_question, remediation, doc_url, maturity.
yaml_to_jsonl() {
  local yaml_file="$1"
  local cat_field="$2"        # e.g. "function" (NIST) or "domain" (FinOps)
  local sub_field="$3"        # e.g. "category" (NIST) or "capability" (FinOps)
  awk -v cat_field="$cat_field" -v sub_field="$sub_field" '
    function strip_quotes(s,    out) {
      out = s
      sub(/^[ \t]*"/, "", out); sub(/"[ \t]*$/, "", out)
      sub(/^[ \t]*\047/, "", out); sub(/\047[ \t]*$/, "", out)
      return out
    }
    function json_escape(s,    out) {
      out = s
      gsub(/\\/, "\\\\", out)
      gsub(/"/,  "\\\"", out)
      gsub(/\t/, "\\t",  out)
      gsub(/\r/, "\\r",  out)
      gsub(/\n/, "\\n",  out)
      return out
    }
    function emit() {
      if (id == "") return
      printf "{\"id\":\"%s\",\"category\":\"%s\",\"subcategory\":\"%s\",", json_escape(id), json_escape(cat), json_escape(subcat)
      printf "\"description\":\"%s\",\"severity\":\"%s\",", json_escape(desc), json_escape(sev)
      printf "\"interactive_question\":\"%s\",\"remediation\":\"%s\",", json_escape(q), json_escape(rem)
      printf "\"doc_url\":\"%s\",\"maturity\":\"%s\"}\n", json_escape(doc), json_escape(mat)
      id=""; cat=""; subcat=""; desc=""; sev=""; q=""; rem=""; doc=""; mat=""
    }
    BEGIN { id=""; cat=""; subcat=""; desc=""; sev=""; q=""; rem=""; doc=""; mat="" }
    /^[[:space:]]*-[[:space:]]+id:/ {
      emit()
      line=$0; sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", line)
      id=strip_quotes(line); next
    }
    /^[[:space:]]+description:/ {
      line=$0; sub(/^[[:space:]]+description:[[:space:]]*/, "", line)
      desc=strip_quotes(line); next
    }
    /^[[:space:]]+severity:/ {
      line=$0; sub(/^[[:space:]]+severity:[[:space:]]*/, "", line)
      sev=strip_quotes(line); next
    }
    /^[[:space:]]+interactive_question:/ {
      line=$0; sub(/^[[:space:]]+interactive_question:[[:space:]]*/, "", line)
      q=strip_quotes(line); next
    }
    /^[[:space:]]+remediation:/ {
      line=$0; sub(/^[[:space:]]+remediation:[[:space:]]*/, "", line)
      rem=strip_quotes(line); next
    }
    /^[[:space:]]+documentation_url:/ {
      line=$0; sub(/^[[:space:]]+documentation_url:[[:space:]]*/, "", line)
      doc=strip_quotes(line); next
    }
    /^[[:space:]]+maturity:/ {
      line=$0; sub(/^[[:space:]]+maturity:[[:space:]]*/, "", line)
      mat=strip_quotes(line); next
    }
    {
      # category-like field (function/domain/etc.)
      if (match($0, "^[[:space:]]+" cat_field ":")) {
        line=$0; sub("^[[:space:]]+" cat_field ":[[:space:]]*", "", line)
        cat=strip_quotes(line); next
      }
      # subcategory-like field (category/capability/subcategory)
      if (match($0, "^[[:space:]]+" sub_field ":")) {
        line=$0; sub("^[[:space:]]+" sub_field ":[[:space:]]*", "", line)
        subcat=strip_quotes(line); next
      }
    }
    END { emit() }
  ' "$yaml_file"
}

build_lens() {
  local source_yaml="$1"
  local out_json="$2"
  local lens_name="$3"
  local lens_desc="$4"
  local cat_field="$5"
  local sub_field="$6"

  local jsonl
  jsonl=$(yaml_to_jsonl "$source_yaml" "$cat_field" "$sub_field")

  # Fold the JSONL into the lens shape: pillars (one per category) →
  # questions (one per check_id) → choices (single choice = the check).
  printf '%s\n' "$jsonl" \
    | jq -s --arg name "$lens_name" --arg desc "$lens_desc" '
        # Group records by .category (function/domain).
        group_by(.category)
        | map({
            id:   (.[0].category | gsub(" "; "_") | ascii_downcase),
            name: .[0].category,
            questions: map({
              id:           .id,
              title:        .interactive_question,
              description:  .description,
              choices: [{
                id:    .id,
                title: .interactive_question,
                helpfulResource: {
                  displayText: .description,
                  url:         .doc_url
                },
                improvementPlan: {
                  displayText: .remediation,
                  url:         .doc_url
                }
              }],
              riskRules: []
            })
          }) as $pillars
        | {
            schemaVersion: "2026-06-04",
            name:          $name,
            description:   $desc,
            pillars:       $pillars
          }
      ' > "$out_json"
}

build_lens \
  "${REF_DIR}/nist-ai-rmf-checks.yaml" \
  "${REF_DIR}/nist-ai-rmf-lens.json" \
  "NIST AI Risk Management Framework Lens" \
  "Canonical question, description, severity, remediation, and documentation URL per NIST AI RMF check. Source: NIST AI RMF Core + GenAI Profile (AI 600-1)." \
  "function" \
  "category"

build_lens \
  "${REF_DIR}/finops-ai-checks.yaml" \
  "${REF_DIR}/finops-ai-lens.json" \
  "FinOps for AI Lens" \
  "Canonical question, description, severity, remediation, maturity tier, and documentation URL per FinOps for AI check. Source: FinOps Foundation FinOps for AI working group asset library." \
  "domain" \
  "capability"

echo "build-lenses: wrote nist-ai-rmf-lens.json, finops-ai-lens.json"
