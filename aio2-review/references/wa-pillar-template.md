# WA Pillar Assessment Template

This is the shared scaffolding for every WA sub-skill (`wa-review-security.md`, `wa-review-operational-excellence.md`, etc.). Each sub-skill markdown lists only its deltas from this template:

- Owned check IDs
- Code inspection patterns (keywords to search in workspace code)
- Cross-pillar reference notes
- Remediation links table

If anything is unclear, fall back to this template before adding new prose.

## Sources of truth

- Structural fields per `check_id` (severity, framework, owner, pillars) come from `${SKILL_ROOT}/references/check-registry.json`.
- Title, "About:" display text, and documentation URL per `check_id` come from the lens files: `${SKILL_ROOT}/references/generative-ai-lens.json` (upstream WA GenAI Lens), `${SKILL_ROOT}/references/nist-ai-rmf-lens.json`, and `${SKILL_ROOT}/references/finops-ai-lens.json`. The renderer joins these at output time. Do NOT duplicate canonical text inside sub-skill markdowns or in finding bodies — the renderer pulls it for you.
- `${SKILL_ROOT}/scripts/build-findings-skeleton.sh` seeds JSONL skeletons with the lens-canonical question text and documentation URL automatically.
- **Evaluation criteria** for every WA check come from `${SKILL_ROOT}/references/wa-implementation-guidance.json`, loaded per-check via `get-implementation-guidance.sh`. This is the single source of truth for what each check requires.

## Safety

All AWS CLI commands invoked by the pillar's assessment script are READ-ONLY (`get-*`, `list-*`, `describe-*`). No resources are created, modified, or deleted.

## Workflow

### 1. Evaluate each check against its implementation guidance

For each `check_id`, load its implementation guidance by calling the script **once per check**:

```bash
# ONE call per check_id. Do NOT batch multiple IDs in one invocation.
${SKILL_ROOT}/scripts/get-implementation-guidance.sh GENSEC01_BP01
```

Call the script, read the returned JSON object directly using the IDE's read capabilities, evaluate, then call it again for the next check_id. Do NOT:
- Pass multiple CHECK_IDs in one invocation (the script accepts exactly one positional argument)
- Pipe output through any parser (python, awk, sed, jq)
- Redirect stderr (`2>/dev/null`)
- Combine multiple calls with `&&` or subshells

The returned `implementation_steps` array is the **evaluation criteria** for this check. Each step represents one thing the workload should be doing. Your job is to determine whether each applicable step is satisfied.

Load each check's guidance before you evaluate it. Do NOT skip this step or use summary JSON fields alone to determine status. Every check MUST be evaluated against its implementation steps.

#### Service-context filtering

Many implementation steps are prefixed with a service name ("For Amazon Bedrock...", "For Amazon Q Business...", "For Amazon SageMaker AI...", "For SageMaker AI HyperPod..."). Only evaluate steps that match the services detected in `$DATA_DIR/manifest.json`:

- `agent_ids`, `kb_ids`, `guardrail_ids`, `prompt_ids`, or `flow_ids` non-empty → **Bedrock is present**. Evaluate "For Amazon Bedrock..." steps.
- `endpoint_names` non-empty → **SageMaker is present**. Evaluate "For Amazon SageMaker AI..." steps.
- `agentcore_runtime_ids` non-empty → **AgentCore is present**. Evaluate AgentCore-related steps.
- Steps with **no service prefix** (e.g., "Set up a dashboard...", "Create alarms...", "Develop incident response playbooks...") → **always applicable**.
- Steps for services **NOT** in the manifest (e.g., "For Amazon Q Business..." when no Q Business resources exist, or "For SageMaker AI HyperPod..." when no HyperPod resources exist) → **skip entirely**. Do NOT include them in your evaluation, finding text, or remediation.

#### Per-step evaluation

For each applicable step, determine if it's satisfied using these evidence sources in priority order:

1. **Summary JSON** — Read the pillar's `*-summary.json`. Match summary fields to implementation steps by semantic meaning (e.g., `invocation_logging.enabled == true` answers a step about enabling model invocation logging; `alarms.bedrock_alarm_count > 0` answers a step about configuring alarms).
2. **Raw data files** — If the summary doesn't cover a step, check `$DATA_DIR/data/*.json` for relevant raw CLI output that could confirm or deny the step.
3. **Code inspection** (if `CODE_ACCESS = true`) — Search the workspace for patterns listed in the sub-skill's "Code inspection patterns" section.
4. **Dynamic CLI** — If a step requires data from a service not in the pre-scripted pipeline, use `dynamic-cli.sh` to fetch it (subject to consent flow).
5. **Interactive question** — Ask the user only if none of the above resolves the step.

Record each applicable step's status using the closed 5-value set: `PASS`, `FAIL`, `PARTIAL`, `N/A`, or `PENDING`. Write it into the finding's `steps[]` array — one entry per step, each with `index` (the original step number), `status`, `applicable`, and `evidence`. A step filtered out by service context is still recorded with `applicable: false` (not omitted); all evaluated steps use `applicable: true`.

#### Compound steps

If an implementation step contains multiple requirements joined by conjunctions ("and"), commas, or semicolons (e.g., "Define the name, description, and encryption of that prompt"), treat each sub-requirement as independently verifiable. The step's status is:

- `PASS` — ALL sub-requirements are confirmed by evidence.
- `PENDING` — any sub-requirement lacks evidence (not yet confirmed or contradicted).
- `FAIL` — a sub-requirement is contradicted by evidence while others are confirmed (use `PARTIAL` instead if the step itself is only partially met).

#### Pre-derivation verification

Before assigning a final status to any step, re-read the step's full text and confirm that every noun and requirement in the sentence has been matched to specific evidence. If you relied on summary JSON that only covers part of the step (e.g., summary shows `name` exists but says nothing about `encryption`), you MUST fall through to the next evidence source (raw data files, code inspection, dynamic CLI, or interactive question) for the uncovered sub-requirements. Do not mark a step `PASS` based on partial evidence coverage.

#### Status derivation

Do NOT derive or set the overall check status for step-bearing checks. Record each step's status in `steps[]`; `merge-findings.sh` derives the check status deterministically from the steps. (See SKILL.md → Status definitions.)

#### Field requirements for step-bearing findings

You do NOT know which overall status `merge-findings.sh` will derive, but `validate-report.sh` enforces required fields against that *derived* status. So include fields based on the **step** statuses, not on the status you expect:

- If any applicable step is `FAIL` or `PARTIAL` → always include a `remediation` field (the derived status may be `FAIL` or `PARTIAL`, which require it).
- If any applicable step is `PENDING` → always include a `question` field (an unresolved step makes the parent derive to `PENDING`, which requires it).
- Always include the `finding` text (required for `PASS`/`FAIL`/`PARTIAL`).

Providing these whenever the corresponding step status is present is safe: unused fields are harmless, and it prevents a post-merge validation failure when the derived status turns out to need them.

#### Finding text format

The `finding` field MUST enumerate each applicable implementation step and its status. Use numbered format matching the guidance's step numbering:

> "1/[Step summary]: PASS — [brief evidence]. 3/[Step summary]: FAIL — [evidence]. ..."

Steps skipped due to service-context filtering should NOT appear in the finding. The numbering should match the original step numbers from the guidance (skip filtered step numbers).

#### Remediation scoping

The `remediation` field MUST reference ONLY the steps that are `FAIL` or `PARTIAL`. Use the implementation guidance's own language for the remediation, scoped to the workload's detected service type. Never recommend actions from a different service's steps.

### 2. Run the assessment script and read the summary

If `CLOUD_ACCESS = true`, run:

```bash
${SKILL_ROOT}/scripts/<pillar-script>.sh \
  --region "$AWS_REGION" \
  --data-dir "$DATA_DIR" \
  [--profile "$AWS_PROFILE"]
```

The script reads every resource ID it needs from `$DATA_DIR/manifest.json`. Pass only the common flags above; the per-resource flags shown in `usage()` are accepted for backwards compatibility but the manifest is the source of truth.

Then read `$DATA_DIR/<pillar>-summary.json`. The summary fields provide **evidence** for evaluating the implementation steps loaded in Section 1. Match summary fields to implementation steps by their semantic meaning. Treat any field that is null or missing as unresolvable via this evidence source — move to the next source (code inspection, dynamic CLI, or interactive question).

If the script exits with code 1 (fatal error), you cannot auto-assess any step — fall through to code inspection and interactive questions for the entire pillar. If the script exits with code 2 (partial), use the data that is present and fall through for steps without evidence.

### 3. Code inspection (if `CODE_ACCESS = true`)

Use the IDE's built-in grep/search tool to search the workspace for the patterns listed in the sub-skill's "Code inspection patterns" section. Do NOT run bash `grep`, `find`, `rg`, or `ag` commands — use the IDE's search capability so results appear in context without shell pipeline composition. Mark code-assessed checks with `method: "code"` in the finding.

### 4. Interactive questions (for PENDING steps)

After using the summary JSON, raw data, and code inspection, some implementation steps may still be `PENDING`. For each pending step, ask a targeted question derived from that step's text. Keep questions concise and specific to the step.

Group pending steps for the same check into a single multi-part question when possible.

Always offer a skip option:

> You can answer, say "skip" to mark as pending, or "skip all" to skip remaining questions in this section.

If the user skips a question, says "I don't know", or you move on without asking, set that step's status to `PENDING` with `method: "needs-input"` — never silently drop the step. Conditional checks for resource types not present in this solution must be marked `N/A` with a `reason` rather than omitted.

### 5. Build and merge findings

Use `build-findings-skeleton.sh` to start with a JSONL skeleton populated from the registry and bundled YAML, then edit only the deltas (status overrides, finding/remediation/reason text):

```bash
${SKILL_ROOT}/scripts/build-findings-skeleton.sh \
    --owner "<this sub-skill's owner from owned-checks.json>" \
    --output "$DATA_DIR/_work/findings/<pillar>.jsonl"

# Edit "$DATA_DIR/_work/findings/<pillar>.jsonl" — flip statuses to PASS /
# FAIL / PARTIAL / N/A as evidence dictates, fill in finding /
# remediation / reason text. PENDING lines can stay as-is.

${SKILL_ROOT}/scripts/check-ownership.sh \
    --owner "<this sub-skill's owner>" \
    --input "$DATA_DIR/_work/findings/<pillar>.jsonl"

${SKILL_ROOT}/scripts/merge-findings.sh \
    --data-dir "$DATA_DIR" \
    --input "$DATA_DIR/_work/findings/<pillar>.jsonl" \
    --partial
```

`--partial` skips post-merge coverage validation, which is expected to fail mid-review while other pillars have not yet been merged. The orchestrator (or the report finalizer) runs `validate-report.sh` once after every pillar has been merged.

Use `--replace` only when intentionally updating an already-merged finding.

Closed sets and field-by-status rules live in SKILL.md → "Helper Closed Sets" and `${SKILL_ROOT}/references/report-schema.md`.
