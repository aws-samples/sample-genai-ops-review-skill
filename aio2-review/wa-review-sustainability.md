# Sustainability Pillar Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-sustainability.sh` → writes `$DATA_DIR/sustainability-summary.json`.

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

4 IDs (`WA:Sustainability` in `references/owned-checks.json`):

```
GENSUS01_BP01, GENSUS01_BP02, GENSUS02_BP01, GENSUS03_BP01
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENSUS01_BP01`: auto-scaling/serverless — `ScalableTarget`, `autoscaling`, `scaling_policy`. Lambda > EC2/ECS for energy efficiency.
- `GENSUS01_BP02`: managed customization — `create-model-customization-job`, `fine_tuning`, `distillation`. Prefer Bedrock-managed over self-managed training.
- `GENSUS03_BP01`: model IDs in code; cross-reference GENCOST01_BP01 / GENPERF02_BP03.

## Summary fields for evidence matching

Beyond existing fields, the following enhanced fields are available in `sustainability-summary.json`:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `s3_lifecycle.buckets[].has_lifecycle_rules` | GENSUS02_BP01 | S3 buckets with lifecycle policies for data tiering |
| `s3_lifecycle.buckets[].has_intelligent_tiering` | GENSUS02_BP01 | Intelligent Tiering configured for cost-efficient storage |

Cross-reference `performance-summary.json`:
| `model_customization.has_distillation` | GENSUS03_BP01 | Distillation produces smaller, more efficient models |
| `foundation_models.providers` | GENSUS03_BP01 | Model options for right-sizing to reduce carbon footprint |

## Cross-pillar references

- `GENSUS03_BP01` ↔ `GENCOST01_BP01` and `GENPERF02_BP03`. Reuse those findings; only ask if model selection was not assessed elsewhere.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENSUS01_BP01 | https://docs.aws.amazon.com/wellarchitected/latest/sustainability-pillar/sus_sus_hardware_a2.html |
| GENSUS01_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/custom-models.html |
| GENSUS02_BP01 | https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html |
| GENSUS03_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Sustainability"
```
