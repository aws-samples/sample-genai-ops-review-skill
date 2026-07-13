# Cost Optimization Pillar Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-cost.sh` → writes `$DATA_DIR/cost-summary.json`.

## ⚠️ MANDATORY: Per-step evaluation (DO NOT SKIP)

For EVERY check_id below, you MUST:
1. Run `${SKILL_ROOT}/scripts/get-implementation-guidance.sh <CHECK_ID>`
2. Filter returned steps by workload service type (from manifest.json)
3. Evaluate EACH applicable step as PASS | FAIL | PARTIAL | N/A | PENDING using summary JSON, code inspection, or interactive question; record each in the finding's `steps[]` array (`index`, `status`, `applicable`, `evidence`)
4. Format finding as "1/[Step summary]: PASS|FAIL — [evidence]. 2/..."
5. Do NOT set the overall check status for step-bearing checks — `merge-findings.sh` derives it deterministically from `steps[]` (see SKILL.md → Status definitions)

Full procedure: `${SKILL_ROOT}/references/wa-pillar-template.md` Section 1.
Do NOT shortcut to summary-JSON-only verdicts.

## Owned Check IDs

9 IDs (`WA:Cost` in `references/owned-checks.json`):

```
GENCOST01_BP01, GENCOST02_BP01, GENCOST02_BP02, GENCOST03_BP01,
GENCOST03_BP02, GENCOST03_BP03, GENCOST03_BP04, GENCOST04_BP01,
GENCOST05_BP01
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENCOST01_BP01`: model IDs in code; flag if a large model is used for simple tasks.
- `GENCOST03_BP01`: prompt optimization — `truncate`, `summarize`, `compress`, `max_input_tokens`, `trim`, plus excessive system-prompt length.
- `GENCOST03_BP02`: response length control — `maxTokens`, `max_tokens`, `MaxTokens` in InvokeModel/Converse. PASS if explicitly set. Also covers INVOCATION_TOKEN_BUDGET.
- `GENCOST05_BP01`: stopping conditions — `timeout`, `maxIterations`, `max_iterations`, `stopSequences`, `stop_sequences`, `idleSessionTTL`.
- `GENCOST03_BP03`: caching patterns — `cache`, `prompt_cache`, `PromptCache`, `cached`.

## Summary fields for evidence matching

Cross-reference `performance-summary.json` for model right-sizing checks:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `foundation_models.available_count` / `foundation_models.providers` (perf summary) | GENCOST01_BP01 | Available models for cost-performance comparison |
| `model_customization.has_distillation` (perf summary) | GENCOST01_BP01 | Distillation reduces cost via smaller models |

## Cross-pillar references

- `GENCOST05_BP01` ↔ `GENREL03_BP02`. Reference; focus on runaway-cost prevention.
- `GENCOST04_BP01` ↔ `GENPERF04_BP02`. Reference.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENCOST01_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html |
| GENCOST02_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/prov-throughput.html |
| GENCOST02_BP02 | https://docs.aws.amazon.com/sagemaker/latest/dg/endpoint-auto-scaling.html |
| GENCOST03_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-parameters.html |
| GENCOST03_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-parameters.html |
| GENCOST03_BP03 | https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html |
| GENCOST03_BP04 | https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html |
| GENCOST04_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html |
| GENCOST05_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/agents-create.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Cost"
```
