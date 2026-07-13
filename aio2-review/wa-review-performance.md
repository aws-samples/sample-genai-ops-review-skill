# Performance Efficiency Pillar Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-performance.sh` → writes `$DATA_DIR/performance-summary.json`.

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

8 IDs (`WA:Performance` in `references/owned-checks.json`):

```
GENPERF01_BP01, GENPERF01_BP02, GENPERF02_BP01, GENPERF02_BP02,
GENPERF02_BP03, GENPERF03_BP01, GENPERF04_BP01, GENPERF04_BP02
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENPERF01_BP01`: ground truth — `ground_truth`, `eval_dataset`, `benchmark`, `golden_set`, `test_cases`.
- `GENPERF01_BP02`: metric collection — `latency`, `throughput`, `p50`, `p99`, `putMetricData`, `CloudWatch`. Cross-reference GENOPS02_BP01/BP02.
- `GENPERF02_BP02`: inference parameters — `temperature`, `top_p`, `topP`, `max_tokens`, `maxTokens`, `top_k`. PASS if explicitly set; PARTIAL if defaults without rationale.
- `GENPERF02_BP03`: model IDs in code. Cross-reference GENCOST01_BP01.
- `GENPERF03_BP01`: managed/serverless usage. PASS if Bedrock + Lambda + SageMaker (managed) only.

## Summary fields for evidence matching

Beyond existing fields (evaluation_jobs, provisioned_throughput, inference_profiles), the following enhanced fields are available in `performance-summary.json`:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `foundation_models.available_count` / `foundation_models.providers` | GENPERF02_BP03, GENCOST01_BP01 | Available models and providers for comparison |
| `mlflow.tracking_server_count` | GENPERF01_BP02 | MLflow experiment tracking infrastructure |
| `model_customization.job_count` / `model_customization.has_distillation` | GENPERF02_BP03 | Distillation/fine-tuning for model optimization |

## Cross-pillar references

- `GENPERF02_BP03` ↔ `GENCOST01_BP01`. Reference; focus on latency/quality fit.
- `GENPERF01_BP02` ↔ `GENOPS02_BP01/BP02`. Reference; focus on quality metrics in addition to operational metrics.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENPERF01_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/model-evaluation.html |
| GENPERF01_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-cw.html |
| GENPERF02_BP01 | https://docs.aws.amazon.com/sagemaker/latest/dg/endpoint-auto-scaling.html |
| GENPERF02_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-parameters.html |
| GENPERF02_BP03 | https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html |
| GENPERF03_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html |
| GENPERF04_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html |
| GENPERF04_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Performance"
```
