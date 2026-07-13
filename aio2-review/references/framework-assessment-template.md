# NIST / FinOps Framework Assessment Template

Shared scaffolding for `nist-ai-rmf-assessment.md` and `finops-ai-assessment.md`. Each sub-skill lists only the deltas: owned IDs (split across functions/domains), CLI fields it consumes, and a cross-pillar reference table.

## Safety

All AWS CLI commands invoked by the assessment script are READ-ONLY. No resources are created, modified, or deleted.

## Inputs

- `REVIEW_SCOPE` — `Code Review`, `Cloud Review`, or `Full Review`.
- `manifest.json` resource context.

## Workflow

### 1. Load check definitions

Read `${SKILL_ROOT}/references/<framework>-ai-checks.yaml` (the editorial source, used to regenerate the lens) for assessment metadata: `id`, `function`/`domain`, `assessment_methods`, `code_patterns`, `cli_commands`, `severity`, plus FinOps-only `maturity`. Read `${SKILL_ROOT}/references/<framework>-ai-lens.json` (generated from the YAML) for canonical question text, description, and documentation URL — these flow through `build-findings-skeleton.sh` and the renderer automatically. Do not duplicate question text or URLs in the sub-skill markdown.

### 2. Filter by scope

- Code Review → run `code` and `interactive` methods only.
- Cloud Review → run `cloud` and `interactive` methods only.
- Full Review → run all methods.

### 3. Run the assessment script

If CLOUD_ACCESS = true, run the framework's assessment script (the sub-skill names it). Read the resulting `<framework>-summary.json` and treat its fields as supplementary evidence: present and populated → positive signal; null or missing → gap signal that needs an interactive answer.

### 4. Cross-pillar references

Before asking any interactive question, check whether a WA pillar finding already covers it. Use the cross-reference table in the sub-skill. For each overlap:

- WA finding PASS → mark this check PASS with a note: "Covered by WA finding `<CHECK_ID>`." Only ask the question if the framework requirement goes beyond what the WA check assessed.
- WA finding FAIL/PARTIAL → reference and inherit status (use `method: "cross-ref"`).
- WA finding PENDING → do NOT mark cross-ref; treat as unresolved and use the canonical `interactive_question` here.
- WA finding not yet assessed → proceed with this check normally.

### 5. Build and merge findings

Same flow as the WA pillars (see `wa-pillar-template.md`):

```bash
${SKILL_ROOT}/scripts/build-findings-skeleton.sh \
    --owner "<all owners for this framework>" \
    --output "$DATA_DIR/_work/findings/<framework>.jsonl"

# Edit only the deltas, then:

${SKILL_ROOT}/scripts/check-ownership.sh \
    --owner "<owner1>" --owner "<owner2>" ... \
    --input "$DATA_DIR/_work/findings/<framework>.jsonl"

${SKILL_ROOT}/scripts/merge-findings.sh \
    --data-dir "$DATA_DIR" \
    --input "$DATA_DIR/_work/findings/<framework>.jsonl" \
    --partial
```

For NIST, pass all four NIST owners. For FinOps, pass all four FinOps owners.

`merge-findings.sh` looks up framework, function/domain, title, severity, and pillars from the registry — you only supply narrative (and `maturity` for FinOps). `interactive_question` for PENDING records is pre-filled by `build-findings-skeleton.sh` straight from the YAML; never paraphrase it.

If the user skips a question or you move on without asking, set `status: "PENDING"` — do not silently drop.
