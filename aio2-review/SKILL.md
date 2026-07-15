---
name: aio2-review
description: >
  AI Operations & Optimization (AIO2) is used to review AWS GenAI 
  workloads against the AWS Well-Architected GenAI Lens, NIST AI 
  Risk Management Framework, and FinOps Foundation FinOps for AI. 
  The skill orchestrates a multi-framework review of Bedrock Agents 
  and Bedrock AgentCore workloads. It accepts a Bedrock Agent ARN, 
  CloudFormation/Terraform stack, or an AWS Resource Group as 
  input, and coordinates framework-specific checks to produce a 
  unified prioritized gap analysis report. Do NOT use for non-AWS 
  reviews or general architecture advice. Activate this skill when 
  the user says "AIO2 review", "AIO2", or "AI operations review".
---

# AWS AI Operations & Optimization (AIO2) Multi-Framework Review — Orchestrator

## Activation Aliases

This skill can be activated by any of the following phrases:
- "aio2-review"
- "AIO2 review"
- "AIO2"

## Safety

This skill performs READ-ONLY operations only. All AWS CLI commands are read-only (`get-*`, `list-*`, `describe-*`). No resources are created, modified, or deleted. The only files written are the review data directory (`aio2-data-*/`) containing raw JSON, summary files, and the report (`report.md` and `report.html`).



## Agent Execution Constraints

The agent is a WORKFLOW EXECUTOR, not a script author. Its permitted execution surface is:

**ALLOWED:**
1. Invoke scripts listed in `${SKILL_ROOT}/scripts/` with their documented arguments
2. Use the IDE's file-read tool to read JSON/YAML/JSONL files
3. Use the IDE's file-write/edit tool to author JSONL findings files under `$DATA_DIR/_work/`
4. Use the IDE's grep/search tool for code inspection patterns listed in sub-skills
5. Use `jq` ONLY in the exact patterns shown in this document (manifest field extraction, `set-narrative.sh --json`)

**FORBIDDEN:**
- Compose shell pipelines, one-liners, or multi-command chains not documented in this skill
- Invoke interpreters (python, node, perl, awk, sed) for any purpose
- Suppress stderr (`2>/dev/null`, `2>&1`) on any skill script invocation
- Chain commands with `&&`, `||`, or `|` beyond what is shown verbatim in this document
- Change working directory (`cd`) before invoking skill scripts — all scripts resolve paths via `SCRIPT_DIR` internally
- Pass arguments not documented in a script's usage (including multiple values where one is expected)
- Wrap, batch, or parallelize script calls in ways not prescribed by this skill
- Run `aws` CLI commands directly — all AWS access goes through pillar scripts or `dynamic-cli.sh`

## Workflow

**IMPORTANT: Do NOT start the review, inspect code, or build a report until you have asked the user the questions below and collected their input. The review is conversational — the user chooses the scope and frameworks first.**

**CLOUD-FIRST RULE: If `CLOUD_ACCESS = true` (Cloud Review or Full Review), you MUST complete Steps 3, 4, and 5 (profile/region selection, cloud resource input collection, and resource discovery) BEFORE starting any code inventory or code analysis in Step 6. Do not scan code, invoke the context gatherer, or begin framework execution until the cloud pipeline has succeeded. `discover-resources.sh` validates credentials on your behalf in Step 5 and will fail fast with a human-friendly message if authentication is broken.**

### 1. Select Review Scope

Ask the user FIRST — before doing anything else:

> What scope would you like for this review?
> 1. **Code Review** — Analyzes workspace code: IaC templates, Lambda handlers, system prompts, SDK calls, tests, and CI/CD configs. No AWS resource assessment API calls.
> 2. **Cloud Review** — Queries the live AWS environment: deployed resources, IAM policies, guardrails, logging, networking, and alarms. No code inspection.
> 3. **Full Review** — Both code and cloud. Most comprehensive.

**STOP and wait for the user's answer.** Do not proceed until the user has selected a scope.

Store selection as `REVIEW_SCOPE`:
- Code Review: `CODE_ACCESS = true, CLOUD_ACCESS = false`
- Cloud Review: `CODE_ACCESS = false, CLOUD_ACCESS = true`
- Full Review: `CODE_ACCESS = true, CLOUD_ACCESS = true`

### 2. Select Frameworks

Then ask:

> Which frameworks would you like to assess against?
> 1. **AWS Well-Architected** — GenAI Lens: 6 core pillars (Security, Ops Excellence, Reliability, Performance, Cost, Sustainability)
> 2. **NIST AI RMF** — AI Risk Management Framework (Govern, Map, Measure, Manage) + GenAI Profile
> 3. **FinOps for AI** — FinOps Foundation AI cost management, optimization, and value alignment
> 4. **All** — Run all three frameworks

**STOP and wait for the user's answer.** Do not proceed until the user has selected frameworks.

Store selection as `SELECTED_FRAMEWORKS`:
- AWS Well-Architected → `"wa"`
- NIST AI RMF → `"nist"`
- FinOps for AI → `"finops"`
- All → `"all"` (equivalent to `"wa,nist,finops"`)

This value is passed directly to `discover-resources.sh --frameworks` in Step 5b.

### 3. Select AWS CLI Profile and Region (Cloud Review or Full Review only)

**Skip this step if `CLOUD_ACCESS = false` (Code Review).**

Ask the user:

> Would you like to use a specific AWS CLI profile for this review?
> 1. **Default** — Use the currently configured AWS CLI credentials (no `--profile` flag)
> 2. **Named profile** — Specify a profile name from your `~/.aws/config`
>
> Which AWS region should be used for resource queries?

Store the selections:
- `AWS_PROFILE` — the profile name, or empty string for default
- `AWS_REGION` — the region (e.g., `us-east-1`)
- `PROFILE_FLAG` — `"--profile <AWS_PROFILE>"` if set, otherwise empty string

**Do NOT run `aws sts get-caller-identity` here.** `discover-resources.sh` in Step 5 validates credentials, captures `ACCOUNT_ID` and `IDENTITY_ARN` into `manifest.json`, and exits with a clear error message if authentication fails. Pre-validating here duplicates that work and slows down the review.

### 4. Collect Cloud Input (Cloud Review or Full Review only)

**Skip this step if `CLOUD_ACCESS = false` (Code Review).**

The user must provide ONE of:

**Option A — Bedrock Agent ARN:**
Validate format `arn:aws:bedrock:[a-z0-9-]+:\d{12}:agent/[A-Z0-9]+`. Extract `AGENT_ID` and `ACCOUNT_ID` from the ARN itself (field 5, colon-delimited). Use `AWS_REGION` from Step 3. The discover script in Step 5 will also populate `ACCOUNT_ID` in `manifest.json` for you.

**Option B — CloudFormation Stacks ARN or Terraform Project Directory:**
```bash
aws cloudformation get-template --stack-name <STACK_ARN> --template-stage Original --region <AWS_REGION> <PROFILE_FLAG> --query TemplateBody --output json
aws cloudformation list-stack-resources --stack-name <STACK_ARN> --region <AWS_REGION> <PROFILE_FLAG> --output json
```
For Terraform, if the user indicates their infrastructure is managed by Terraform, use `--tf-state-dir` pointing to the Terraform project directory. The discover script runs `terraform state pull` in that directory to read the current state and extract resource IDs. The user must have valid AWS credentials and a configured Terraform backend (local or remote).
Use `${SKILL_ROOT}/references/resource-map.yaml` to identify GenAI-relevant resources.

**Option C — AppRegistry Application ARN:**
```bash
aws servicecatalog-appregistry get-application --application <APP_ID> --region <AWS_REGION> <PROFILE_FLAG> --output json
aws servicecatalog-appregistry list-associated-resources --application <APP_ID> --region <AWS_REGION> <PROFILE_FLAG> --output json
```
For each associated stack, fetch template and resources as in Option B.

**Option D — Resource Group ARN:**
```bash
aws resource-groups list-group-resources --group <GROUP_ARN_OR_NAME> --region <AWS_REGION> <PROFILE_FLAG> --output json
```
Accepts any AWS Resource Group including AppRegistry-managed tag groups (e.g., `arn:aws:resource-groups:us-east-1:890800290540:group/AWS_AppRegistry_AppTag_<account>-<app>`). The discover script classifies each member resource by type and delegates to CFN discovery for any CloudFormation stacks in the group.

### 5a. Setup — Path Convention

When you first read this SKILL.md, note its absolute path on disk. The directory containing this file is SKILL_ROOT. In Kiro this can be in global skill folder ~/.kiro/skills/aio2-review/ or current workspace folder .kiro/skills/aio2-review/

For all script invocations and file reads, replace `${SKILL_ROOT}` with that directory path. For example, if this file is at `~/.kiro/skills/aio2-review/SKILL.md`, then SKILL_ROOT is `~/.kiro/skills/aio2-review/`.



### 5a-bis. Script Invocation Contract

Every script invocation by the agent MUST follow this exact form:

```bash
${SKILL_ROOT}/scripts/<script-name>.sh [--documented-flags]
```

Rules:
1. **No CWD dependency** — Scripts resolve all paths from their own `SCRIPT_DIR`. Never `cd` before calling them.
2. **One invocation, one purpose** — Each call does one thing. Do not chain with `&&`, pipe with `|`, or background with `&`.
3. **Respect the interface** — Pass only flags listed in the script's `--help`. If `--help` says one positional argument, pass exactly one.
4. **Preserve stderr** — Never redirect or suppress stderr. If a script emits an error, report it.
5. **Read output with IDE tools** — When a script writes a file (JSON, JSONL), read it with the IDE's file-read tool. When a script emits JSON to stdout (like `get-implementation-guidance.sh`), capture the full output directly — do not pipe or transform it.

### 5b. Discover Resources (Cloud Review or Full Review only)

**Skip this step if `CLOUD_ACCESS = false` (Code Review).**

Run the discovery script:

```bash
DATA_DIR=$(${SKILL_ROOT}/scripts/discover-resources.sh \
  --region "$AWS_REGION" \
  --review-scope "$REVIEW_SCOPE" \
  --frameworks "$SELECTED_FRAMEWORKS" \
  [--profile "$AWS_PROFILE"] \
  [--agent-arn "$AGENT_ARN" | --stack-name "$STACK_NAME" | --tf-state-dir "$TF_DIR" | --app-arn "$APP_ARN" | --resource-group "$RESOURCE_GROUP"] \
  --solution-name "$SOLUTION_NAME")
```

`$REVIEW_SCOPE` is the literal string the user picked in Step 1: `"Code Review"`, `"Cloud Review"`, or `"Full Review"`. `$SELECTED_FRAMEWORKS` is the comma-separated framework list from Step 2: `"wa"`, `"nist"`, `"finops"`, `"wa,nist,finops"`, or `"all"`. The discover script writes both directly into `manifest.json` and `report.json.metadata`, so the orchestrator does NOT need separate `set-narrative.sh` calls for these fields.

**CRITICAL:** Always pass `--frameworks` matching the user's Step 2 selection. If omitted, the script defaults to `"wa"` only, which causes validation failures when NIST or FinOps findings are merged later.

The script:
- Validates AWS credentials via `sts get-caller-identity` and exits 1 with a clear error if authentication fails
- Creates `aio2-data-<solution>-<date>/`, writes raw JSON to `data/` (including `sts-get-caller-identity.json`)
- Writes `manifest.json` and `report.md` skeleton
- Outputs the data directory path as the last line of stdout

The downstream pillar/framework scripts read all resource IDs from `$DATA_DIR/manifest.json` directly (via `manifest_load_resource_ids` in `_common.sh`). The orchestrator does NOT need to parse the manifest into shell variables and pass them as flags — every script now follows the same invocation contract:

```bash
${SKILL_ROOT}/scripts/<pillar-script>.sh \
  --region "$AWS_REGION" \
  --data-dir "$DATA_DIR" \
  [--profile "$AWS_PROFILE"]
```

If you want to override a single resource family (for example, restrict a pillar to a specific guardrail), the script-specific scoping flags from each sub-skill's Section 1 still take precedence over the manifest. Pillar scripts hard-fail on unknown arguments, so consult the sub-skill markdown's example call before adding flags.

For your own narrative work — for example, summarizing the discovered resources in the executive summary — read the manifest fields with `jq`:
```bash
ACCOUNT_ID=$(jq -r '.account_id'  "$DATA_DIR/manifest.json")
IDENTITY_ARN=$(jq -r '.identity_arn' "$DATA_DIR/manifest.json")
```

**`jq` is sanctioned ONLY for the patterns shown above and in `set-narrative.sh --json` calls.** Do NOT use `jq` to build custom parsing pipelines, transform script output, or compose novel queries. For reading script output (e.g., `get-implementation-guidance.sh`), use the IDE's file-read tool or read the stdout JSON directly — do NOT pipe it through `jq` or any other transformer.

### 6. Collect Code Inventory (Code Review or Full Review only)

**Skip this step if `CODE_ACCESS = false` (Cloud Review).**

Confirm the user is running from within the solution's code workspace. Scan the workspace to build a code inventory:
- IaC templates (CloudFormation, Terraform, CDK)
- Lambda handlers, system prompts, SDK calls
- Test files, CI/CD configs

**NOTE:** In a Full Review, this step runs AFTER the cloud pipeline (Steps 3–5) has completed successfully. This ensures the user is not waiting through a code scan only to discover authentication or resource input issues.

### 7. Pull Check Definitions for Selected Frameworks

**CRITICAL: Every framework sub-skill file contains the authoritative check IDs. You MUST read the sub-skill file and use ONLY the check_ids defined there or in `${SKILL_ROOT}/references/check-registry.json`. NEVER invent check IDs.**

Check definitions are bundled with the skill. Two files split the responsibility:

- **`${SKILL_ROOT}/references/check-registry.json`** is the structural index of every check_id: framework membership, canonical owner, severity, AI Ops pillar mapping, default applicability. It does NOT carry the canonical question text — that lives in the lens files.
- **Lens JSON files** (one per source) carry the canonical title, display text, and documentation URL for every check. They follow the same grammar as the upstream AWS Well-Architected GenAI Lens JSON (pillars → questions → choices, with `helpfulResource` and `improvementPlan` per choice):
  - `${SKILL_ROOT}/references/generative-ai-lens.json` — verbatim copy of the upstream AWS Well-Architected GenAI Lens (51 best practices across 6 pillars). Source of truth for `GENOPS*`, `GENSEC01-06`, `GENREL*`, `GENPERF*`, `GENCOST*`, `GENSUS*`.
  - `${SKILL_ROOT}/references/nist-ai-rmf-lens.json` — generated from `nist-ai-rmf-checks.yaml` by `${SKILL_ROOT}/scripts/build-lenses.sh`.
  - `${SKILL_ROOT}/references/finops-ai-lens.json` — generated from `finops-ai-checks.yaml` by `${SKILL_ROOT}/scripts/build-lenses.sh`.

The renderer (`generate-report.sh`) joins findings → registry (severity, pillars, owner) → lens (title, description, URL) at render time. The agent never authors title or display text — those come from the lens. The agent authors only the per-finding `finding`, `remediation`, `reason`, or `question` text.

There is no Well-Architected Tool API call here. The bundled JSON files are the authoritative source.

#### How findings are organized in the report

The renderer groups all findings by WA Pillar → Sub-category (lens question), creating one section per sub-category in both `report.md` and `report.html`. Within each sub-category, findings are ordered by severity (CRITICAL → HIGH → MEDIUM → LOW), then by status within each severity tier (FAIL → PARTIAL → PENDING → PASS → N/A). The Summary table at the top links to each sub-category's detailed section.

### 8. Present Summary

Show the user:
- AWS Profile and Region being used
- Account ID and identity
- Solution type(s) detected (Agent, Flow, KB, SageMaker, Direct Invocation, etc.)
- Resource inventory (count by type, with actual IDs)
- Which frameworks will run
- Which check categories apply based on discovered resources and selected scope
- Number of CLI commands in the command plan
- Any skipped command blocks (resource types not present)

### 9. Report Skeleton (already written by discover-resources.sh)

`discover-resources.sh` (Step 5b) wrote `$DATA_DIR/report.json` with the metadata header, an empty `findings[]` array, and an empty Executive Summary. From here on, all updates to `report.json` go through deterministic helpers under `${SKILL_ROOT}/scripts/`:

- `build-findings-skeleton.sh --owner <owner> [--owner ...] [--output <file>]` — emits a JSONL skeleton with one PENDING line per `check_id` owned by the listed owner(s), pre-populated with canonical question text and documentation URL from the lens files. Run this first for each sub-skill, then edit only the deltas (override status to PASS/FAIL/PARTIAL/N/A and fill `finding` / `remediation` / `reason` text) before merging.
- `lens-lookup.sh --owner <owner> | --check-id <id> | --pillar <lens-pillar> [--format markdown|json|full]` — returns the canonical title, About text, improvement plan, and documentation URL for every check matching the selectors. Use it from sub-skills instead of duplicating prose pointers; default markdown output is a compact table suitable for inline reference.
- `check-ownership.sh --owner <key> --input <file.jsonl>` — verifies that a sub-skill's batch covers exactly the set of `check_id`s owned by that sub-skill (per `references/owned-checks.json`). Use it before merging to catch missing or extra IDs early.
- `merge-findings.sh --input <file.jsonl> [--partial]` — atomically merges a batch of findings into `report.json`. Validates every record against the Check Registry and the closed sets, snapshots `report.json` before applying, and rolls back if post-merge validation fails. Pass `--partial` for every batch except the last to skip the post-merge coverage validation (suppresses the "FATAL: ... rc=3" log line that otherwise appears when not all framework checks are merged yet).
- `set-narrative.sh --section <name> --text "…"` — sets Executive Summary prose / metadata fields. The prose should be 3 paragraphs incorporating strengths and critical findings.
- `validate-report.sh` — runs against `report.json` and the registry; reports closed-set / required-field / coverage failures. Other helpers call it automatically; you can call it directly when you need a check.
- `generate-report.sh` — renders both `report.md` and `report.html` from `report.json` + the HTML template. Refuses to run unless `validate-report.sh` passes.

Do NOT call `fsWrite` or `fsAppend` against `report.json`, `report.md`, or `report.html`. The helpers own all structural text. You supply only narrative content (Finding text, Remediation text, Question text, Reason text, prose paragraphs, bullet items).

**Working files convention:** Transient agent-authored inputs (per-sub-skill JSONL skeletons, narrative drafts, scratch text) MUST live under `$DATA_DIR/_work/`:

- `$DATA_DIR/_work/findings/<owner>.jsonl` — output of `build-findings-skeleton.sh` and any hand-edited findings batches before `merge-findings.sh`.
- `$DATA_DIR/_work/drafts/exec-prose.txt|exec-strengths.txt|exec-critical.txt` — narrative draft text consumed by `set-narrative.sh --text-file`.
- `$DATA_DIR/_work/` is a convention, not a hard requirement. The canonical artifacts (`report.json`, `report.md`, `report.html`, `manifest.json`, `*-summary.json`, `data/`) stay at `$DATA_DIR/` root. Anything under `_work/` is safe to delete after the report has been generated.

### 10. Execute Frameworks

Process each selected framework in order. Each framework skill runs its assessment script, reads the summary JSON, asks follow-up questions, and appends findings to the report before the next framework begins.

**How sub-skills work:** Each sub-skill markdown is a delta document — owned check IDs, code inspection patterns, cross-pillar references, and remediation links only. Evaluation criteria come from `${SKILL_ROOT}/references/wa-implementation-guidance.json` via `get-implementation-guidance.sh`, following the workflow in `${SKILL_ROOT}/references/wa-pillar-template.md`. The agent loads implementation steps for each check, filters by the workload's detected service type (from manifest.json), and evaluates each applicable step against the summary JSON, code, or interactive input. The shared workflow scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md` (for WA) and `${SKILL_ROOT}/references/framework-assessment-template.md` (for NIST and FinOps). Read the template for the full procedure; read the sub-skill for the deltas.

For each sub-skill, the canonical authoring flow is:

```bash
${SKILL_ROOT}/scripts/build-findings-skeleton.sh \
    --owner "<sub-skill owner>" \
    --output "$DATA_DIR/_work/findings/<pillar>.jsonl"
# Edit deltas in $DATA_DIR/_work/findings/<pillar>.jsonl
${SKILL_ROOT}/scripts/check-ownership.sh \
    --owner "<sub-skill owner>" \
    --input "$DATA_DIR/_work/findings/<pillar>.jsonl"
${SKILL_ROOT}/scripts/merge-findings.sh \
    --data-dir "$DATA_DIR" \
    --input "$DATA_DIR/_work/findings/<pillar>.jsonl" \
    --partial   # omit on the LAST batch only
```

For the orchestrator script invocations themselves, every pillar script still follows the same contract from Step 5b.

**If WA selected — run the 6 WA pillars:**

1. **Security** — read `${SKILL_ROOT}/wa-review-security.md` and follow its instructions (CRITICAL checks first)
2. **Operational Excellence** — read `${SKILL_ROOT}/wa-review-operational-excellence.md` and follow its instructions
3. **Reliability** — read `${SKILL_ROOT}/wa-review-reliability.md` and follow its instructions
4. **Performance Efficiency** — read `${SKILL_ROOT}/wa-review-performance.md` and follow its instructions
5. **Cost Optimization** — read `${SKILL_ROOT}/wa-review-cost.md` and follow its instructions
6. **Sustainability** — read `${SKILL_ROOT}/wa-review-sustainability.md` and follow its instructions

After pillar 6, announce: "All 6 WA pillars complete."

**Progress tracking — after each pillar, report progress accurately:**
- Use "WA Pillar X of 6 complete" for core pillars (1–6)

After each pillar, tell the user which one completed and which is next.

**If NIST selected:**
Read `${SKILL_ROOT}/nist-ai-rmf-assessment.md` and follow its instructions. It runs all 4 functions (Govern, Map, Measure, Manage), runs its assessment script for CLI checks, handles its own interactive questions, and appends findings tagged `[NIST]`.

**If FinOps selected:**
Read `${SKILL_ROOT}/finops-ai-assessment.md` and follow its instructions. It runs all 4 domains, runs its assessment script for CLI checks, handles its own interactive questions, and appends findings tagged `[FinOps]`.

### 11. Finalize Report

**ALWAYS run this step automatically when all frameworks are done. Do NOT ask the user whether to generate the HTML report — just generate it. The report is the primary deliverable of this skill.**

Before generating, fill in the narrative sections via `set-narrative.sh` (read `${SKILL_ROOT}/aio2-review-report-finalizer.md` for the exact calls). Then render:

```bash
${SKILL_ROOT}/scripts/generate-report.sh \
  --data-dir "$DATA_DIR" \
  --template "${SKILL_ROOT}/references/report-finalizer-template.html"
```

The renderer:
- Calls `validate-report.sh` first; refuses to render unless validation passes (every active-framework `check_id` present, no duplicates, every closed-set value valid, every required narrative field present per status).
- Reads `report.json` and `${SKILL_ROOT}/references/check-registry.json`.
- Writes `$DATA_DIR/report.md` and `$DATA_DIR/report.html` in one pass.

If validation fails, fix the offending findings via `merge-findings.sh --replace` (or `set-narrative.sh` for narrative gaps) and re-run `generate-report.sh`. There is no `--force` mode — the renderer is purely declarative over `report.json`.

## Check Registry and Lens Files

The skill uses two complementary sources for every check:

- **`${SKILL_ROOT}/references/check-registry.json`** — structural index of every `check_id`, with `frameworks`, `category`, `canonical_owner`, `severity`, `pillars`, `default_applicability`, and the optional `requires_user_input` flag (see below). The registry intentionally does NOT carry title or description text; those fields are sourced at render time from the lens files.
- **Lens JSON files** — one per source, all in the same WA-Lens grammar (pillars → questions → choices, with `helpfulResource.displayText` and `helpfulResource.url` per choice):
  - `generative-ai-lens.json` (verbatim from AWS Well-Architected GenAI Lens)
  - `nist-ai-rmf-lens.json` (generated from NIST YAML)
  - `finops-ai-lens.json` (generated from FinOps YAML)

`generate-report.sh` joins findings → registry → lens at render time. The lens supplies the canonical title, "About:" display text, and documentation URL for every check shown in the report. The agent authors only finding / remediation / reason / question text.

`${SKILL_ROOT}/scripts/build-lenses.sh` regenerates the NIST and FinOps lens files from their YAML sources. Run it whenever the YAML changes.

### Checks that require manual user input

Some checks cannot be resolved from CLI data or workspace code — only a human can answer them (e.g. governance policy, business-value, and FinOps-practice questions). In the framework YAMLs these have `assessment_methods: ["interactive"]` and nothing else. The registry marks them with `requires_user_input: true`, and this is enforced deterministically:

- `build-findings-skeleton.sh` already emits them as `PENDING` / `needs-input`, so the default is correct.
- `merge-findings.sh` and `validate-report.sh` reject any `requires_user_input` finding that carries a non-`PENDING` status unless `method` is `interactive` (the user answered) or `cross-ref` (a WA finding covered it). This makes "marked FAIL/PASS without ever asking the user" impossible to ship — the report will not generate.
- `${SKILL_ROOT}/scripts/audit-manual-input.sh` re-derives the interactive-only set from the YAMLs and verifies the registry flags match (run it after editing the YAMLs). `audit-manual-input.sh --list` prints the full mapping of manual-input checks.

If you present one of these questions and the user skips it (or you never got to ask), the finding MUST stay `PENDING` with a `question`. Do not substitute a FAIL or PASS.

## Resource Discovery

`${SKILL_ROOT}/scripts/discover-resources.sh` detects resources across eight families:

| # | Family | Manifest key |
|---|--------|--------------|
| 1 | Bedrock Agents | `agent_ids` |
| 2 | AgentCore Runtimes | `agentcore_runtime_ids` |
| 3 | Knowledge Bases | `kb_ids` |
| 4 | Bedrock Guardrails | `guardrail_ids` |
| 5 | AgentCore Gateways | `agentcore_gateway_ids` |
| 6 | AgentCore Identity | `agentcore_identity_ids` |
| 7 | AgentCore Memory | `agentcore_memory_ids` |
| 8 | Bedrock Prompts | `prompt_ids` |

**Foundation model resolution (source of truth).** `discover-resources.sh`
resolves each solution component's foundation model through a priority chain and
records the result plus its provenance (`source`) in `manifest.json`:

1. **Inference profiles** — the script gathers Bedrock inference profiles
   (`list-inference-profiles` / `get-inference-profile`, read-only) and, when a
   component references an inference profile id/arn as its model, resolves the
   underlying `modelArn`(s) rather than recording the profile id. Manifest:
   `inference_profiles[]` and `source: inference_profile`.
2. **Direct CLI model field** — else the read-only field on the component's
   response (e.g. `bedrock-agent get-agent` `foundationModel`). `source: cli_field`.

Components the script cannot resolve via steps 1–2 are recorded on
`models_needing_resolution[]` in `manifest.json` (no model entry, no source
written). Scripts stay non-interactive.

#### Orchestrator model fallback (`models_needing_resolution[]`)

After discovery, read `manifest.json → models_needing_resolution[]`. For each
component id listed, apply the fallback in order:

| Step | Action | `source` value | When |
|------|--------|----------------|------|
| 1 | Derive from workspace IaC/source (Terraform, CFN, SDK calls) | `code` | Code Review or Full Review |
| 2 | Ask the user (with skip option) | `user` | Step 1 did not resolve |
| 3 | Record undetermined | `undetermined` | User skipped — last resort only |

- Step 1 is an orchestrator action: inspect the code inventory from Step 6.
- Step 2 is an orchestrator action: prompt the user for the model id. Always
  offer a skip option.
- Never write `undetermined` without exhausting steps 1 and 2 first.

**After resolving all models**, propagate the final model list to `report.json`:

```bash
${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" \
  --section metadata.models \
  --json "$(jq '[.models[] | if type == "object" then .model_id else . end] | unique' "$DATA_DIR/manifest.json")"
```

This step is required even when `models_needing_resolution[]` was empty — the discovery script may have resolved models into `agentcore_runtime_models` or `bedrock_agent_models` that are already in `manifest.json.models` but not yet in `report.json.metadata.models`.

**Halt behavior:**

- **Zero resources (exit 3):** When scoped discovery yields zero resources across all families, the script halts before any framework executes. No account-wide fallback sweep is performed. The orchestrator surfaces the message and stops.
- **Authorization error (exit 4):** When a required API call returns an authorization error, the script halts, names the family and failing operation, and waits for the user to resolve the issue before any re-invocation.

## Dynamic CLI Fallback

When the orchestrator needs data from a service outside the pre-scripted pipeline, it uses `${SKILL_ROOT}/scripts/dynamic-cli.sh` — an opt-in read-only helper.

**`dynamic-cli.sh` is the ONLY mechanism for agent-originated AWS CLI commands.** The agent MUST NOT run `aws` commands directly, compose `aws` pipelines, or invoke AWS SDKs. All non-scripted AWS access flows through `dynamic-cli.sh` with its allowlist, consent flow, and registry-binding requirements.

**Allowlist:** Only operations prefixed with `get-`, `list-`, `describe-`, `head-`, `lookup-`, or `select-` are accepted. Non-read-only verbs are rejected with `non-read-only verb rejected`.

**Consent flow:**

1. The orchestrator groups planned dynamic commands by AWS service.
2. Before the first batch, it prompts the user with the list of services to be queried.
3. Confirmed services are remembered in the session variable `AIO2_DYNAMIC_CONFIRMED_SERVICES`.
4. Subsequent batches execute without re-prompting unless a new service appears that was not in any previously confirmed batch — in which case the orchestrator prompts again for that new service only.

**`[dynamic]` finding tag:** Findings derived from dynamic CLI data are tagged `[dynamic:<filename>.json]` in the finding heading, naming the file under `${DATA_DIR}/data/` from which the finding was derived.

**Registry binding rule:** Every dynamic finding MUST be bound to a registered `check_id` in the Check Registry. If a finding cannot be bound to any registered `check_id`, the orchestrator discards the finding and logs a warning naming the unmapped service, operation, and source file.

**Output convention:** Results are written to `${DATA_DIR}/data/<service>-<operation>[-<resource-id>].json` matching the existing naming pattern.

## Report Structure

The renderer (`generate-report.sh`) organizes the report by WA Pillar → Sub-category (lens question). The Summary table at the top provides per-sub-category status counts with hyperlinks to detailed sections below. Detailed findings within each sub-category are ordered by severity (CRITICAL first) then status (FAIL → PARTIAL → PENDING → PASS → N/A).

## Helper Closed Sets

Single source of truth for every closed set the report-writing helpers enforce. Sub-skills reference this section instead of repeating it. All values are case-sensitive and exact-match. Any value outside these sets causes the relevant helper to exit non-zero with an error listing the allowed values.

### Status definitions

`PASS | FAIL | PARTIAL | N/A | PENDING` is THE status vocabulary. This one closed set is used everywhere a status is recorded or displayed — both finding status and per-step status (`steps[].status`).

| Value | Meaning |
|---|---|
| `PASS` | The check/step is fully satisfied. |
| `FAIL` | The check/step is not satisfied. |
| `PARTIAL` | Partially satisfied — some sub-requirements met, others not. |
| `N/A` | Not applicable to this workload (no applicable steps remain after service-context filtering). |
| `PENDING` | Unresolved/unknown — evidence was insufficient and the user has not answered. |

`MET`, `NOT_MET`, and `UNRESOLVED` are NOT status values. Any unanswered or unknown evaluation is `PENDING`.

Model_Source provenance values (`inference_profile | cli_field | code | user | undetermined`) are a SEPARATE namespace recording how a foundation model was resolved — they are not status values.

**Parent (lens question) risk vs. status.** A parent question carries two independent values, both derived deterministically in `merge-findings.sh` and stored in `report.json.parent_rollups`:
- **risk** (`NO_RISK | MEDIUM_RISK | HIGH_RISK`) comes from the lens `riskRules` — the lens's severity weighting of the gap. It is never altered.
- **status** is derived from the child sub-checks, not as a pure function of risk. Precedence:
  1. all applicable children `N/A` → `N/A` (risk null);
  2. any applicable child `FAIL` → `FAIL` (a failed best practice is never masked by the risk weighting; `FAIL` outranks `PENDING`);
  3. any applicable child `PENDING` → `PENDING` (an unresolved child leaves the question unresolved, not `PARTIAL`);
  4. otherwise → `risk_to_status(risk)`: `NO_RISK`→`PASS`, `MEDIUM_RISK`→`PARTIAL`, `HIGH_RISK`→`FAIL`.

  So a failed BP on a question whose risk caps at `MEDIUM_RISK` renders **`MEDIUM_RISK` / `FAIL`** — the severity is medium, but the control still failed. The only remaining source of a `PARTIAL` parent is a genuinely `PARTIAL` child (no `FAIL`/`PENDING` siblings) on a `MEDIUM_RISK` question.

**Finding fields (used in `merge-findings.sh` JSONL records and validated by `validate-report.sh`):**
- `status` — `PASS | FAIL | PARTIAL | N/A | PENDING` *(required)*
- `method` — `auto | code | interactive | cross-ref | needs-input` *(default: `auto`; `needs-input` for PENDING)*
- `source` — optional, only `dynamic:<filename>` where filename matches `[A-Za-z0-9._-]+`
- `maturity` — optional, FinOps only: `Crawl | Walk | Run`
- `check_id` — must exist in `${SKILL_ROOT}/references/check-registry.json`
- Required narrative per status: PASS → `finding`. FAIL/PARTIAL → `finding` + `remediation` (and `doc_url` when available). PENDING → `question` (+ optional `why_it_matters`; when `finding`/`remediation` are present from partial step-level assessment, the renderer displays them above the question with a "Reason pending" derived from the PENDING steps). N/A → `reason`.

See `${SKILL_ROOT}/references/report-schema.md` for the full `report.json` schema.

**`set-narrative.sh --section`** — `exec-prose | exec-strengths | exec-critical | metadata.<field>`. Exactly one of `--text`, `--text-file`, `--json` is required.

**Frameworks** (`metadata.frameworks` in `report.json`) — exact-match: `WA`, `NIST`, `FinOps`.

**Review scope** (`metadata.review_scope`) — `Code Review | Cloud Review | Full Review`.

## Rules

- **CLOSED COMMAND SET:** The agent MUST ONLY invoke scripts defined under `${SKILL_ROOT}/scripts/`. Do NOT compose, synthesize, pipe, or wrap commands that are not explicitly documented in this skill. Do NOT pass multiple arguments where a script accepts one. Do NOT invoke python, awk, sed, perl, or any ad-hoc interpreter to parse, transform, or batch skill script output. If a script does not support batching, call it once per item sequentially.
- **ERROR VISIBILITY:** Do NOT suppress stderr (`2>/dev/null`, `2>&1 /dev/null`) or ignore exit codes on any script invocation. Scripts use ERR traps and structured error messages. If a script fails, surface the error to the user and stop — do not mask it and continue.
- **NEGATIVE EXAMPLES (FORBIDDEN — the agent MUST NOT do any of these):**
  ```bash
  # WRONG: Batching multiple IDs into one call
  get-implementation-guidance.sh ID1 ID2 ID3

  # WRONG: Suppressing errors and piping to a custom parser
  get-implementation-guidance.sh ID1 2>/dev/null | python3 -c "import sys..."

  # WRONG: cd-ing to the target workspace before a skill script
  cd /path/to/workspace && ${SKILL_ROOT}/scripts/wa-security.sh ...

  # WRONG: Composing an aws CLI call directly
  aws bedrock list-guardrails --region us-east-1

  # WRONG: Using jq to parse script output
  ${SKILL_ROOT}/scripts/get-implementation-guidance.sh ID1 | jq '.implementation_steps'

  # WRONG: Chaining calls with && or pipes
  ${SKILL_ROOT}/scripts/script-a.sh && ${SKILL_ROOT}/scripts/script-b.sh

  # WRONG: Using --text for architecture or exec-prose (newlines get flattened by shell)
  ${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section architecture --text "┌───┐ │ A │ └───┘"
  ${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section exec-prose --text "Para 1... Para 2... Para 3..."
  # CORRECT: Write to file first, then use --text-file
  ${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section architecture --text-file "$DATA_DIR/_work/drafts/architecture.txt"
  ${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section exec-prose --text-file "$DATA_DIR/_work/drafts/exec-prose.txt"
  ```
  Every script invocation must match the exact documented pattern: one script, documented args, no pipes, no stderr suppression, no CWD change.
- Always run Step 11 (Generate Report) automatically when all frameworks complete — never ask the user for confirmation to generate the report or HTML. The report is the primary deliverable of this skill.
- All updates to `report.json` MUST go through the helpers under `${SKILL_ROOT}/scripts/`: `merge-findings.sh`, `set-narrative.sh`. Do NOT call `fsWrite` or `fsAppend` against `report.json`, `report.md`, or `report.html`. The renderer is the only writer of `report.md` and `report.html`.
- Every check in the Check Registry filtered by `metadata.frameworks` MUST appear in `report.json` exactly once. `validate-report.sh` enforces this; `generate-report.sh` refuses to render unless validation passes. Resource types not present → status `N/A`; user skipped a question → status `PENDING`. Never silently drop a check.
- All AWS CLI commands are READ-ONLY. All CLI commands MUST use `AWS_REGION` and `AWS_PROFILE` from Step 3. CLI commands are executed by pillar scripts in `${SKILL_ROOT}/scripts/`; sub-skills read summary JSON files.
- When presenting interactive questions, ALWAYS offer a skip option. Use phrasing like "You can answer, say 'skip' to mark as pending, or 'skip all' to skip remaining questions in this section." If the user skips, emit a finding with `status: "PENDING"` — do NOT silently drop the check. Applies to all frameworks.
- Checks flagged `requires_user_input: true` in the registry (the `assessment_methods: ["interactive"]` set — see "Checks that require manual user input") can ONLY be resolved by a human answer. If you did not collect an answer, the finding stays `PENDING` with `method: "needs-input"`. Marking such a check PASS/FAIL/PARTIAL/N/A is only valid with `method: "interactive"` (user answered) or `method: "cross-ref"` (covered by a WA finding); `merge-findings.sh` and `validate-report.sh` enforce this and will block report generation otherwise. Run `audit-manual-input.sh --list` to see the full set.
