# Operational Excellence Pillar Assessment

Shared workflow scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-ops-ex.sh` → writes `$DATA_DIR/ops-ex-summary.json`.

## ⚠️ MANDATORY: Per-step evaluation (DO NOT SKIP)

For EVERY check_id below, you MUST:
1. Run `${SKILL_ROOT}/scripts/get-implementation-guidance.sh <CHECK_ID>`
2. Filter returned steps by workload service type (from manifest.json)
3. Evaluate EACH applicable step as PASS | FAIL | PARTIAL | N/A | PENDING using summary JSON, code inspection, or interactive question; record each in the finding's `steps[]` array (`index`, `status`, `applicable`, `evidence`)
4. Format finding as "1/[Step summary]: PASS|FAIL — [evidence]. 2/..."
5. Do NOT set the overall check status for step-bearing checks — `merge-findings.sh` derives it deterministically from `steps[]` (see SKILL.md → Status definitions)

Full procedure: `${SKILL_ROOT}/references/wa-pillar-template.md` Section 1.
Do NOT shortcut to summary-JSON-only verdicts.

Working findings file: `$DATA_DIR/_work/findings/ops-ex.jsonl`

## Owned Check IDs

10 IDs (`WA:Ops Excellence` in `references/owned-checks.json`):

```
GENOPS01_BP01, GENOPS01_BP02, GENOPS02_BP01, GENOPS02_BP02,
GENOPS02_BP03, GENOPS03_BP01, GENOPS03_BP02, GENOPS04_BP01,
GENOPS04_BP02, GENOPS05_BP01
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENOPS04_BP01`: IaC files — `cdk.json`, `template.yaml`, `*.tf`, `*.template`, `Pulumi.yaml`. PASS if present.
- `GENOPS03_BP01`: prompt versioning — `PromptVersion`, `prompt_version`, `prompt-template`, `prompt_catalog`.
- `GENOPS03_BP02`: trace enablement — `enableTrace`, `trace`, `traceEnabled`. PASS if explicitly enabled.
- `GENOPS01_BP01`: evaluation datasets — `ground_truth`, `eval_dataset`, `benchmark`, `golden_set`, `evaluation`. Cross-reference: if GENPERF01_BP01 or BP01_03 already assessed, reference those findings; focus on cadence and stratified sampling.
- `GENOPS01_BP02`: feedback collection — `feedback`, `thumbs_up`, `thumbsUp`, `rating`, `survey`, `user_feedback`.
- `GENOPS02_BP03`: throttling/auto-scaling — `throttle`, `rate_limit`, `RateLimit`, `autoscaling`, `ScalableTarget`, `quota`.
- `GENOPS02_BP01`: dashboards in IaC — `AWS::CloudWatch::Dashboard`, `aws_cloudwatch_dashboard`.
- `GENOPS02_BP02`: alarms in IaC — `AWS::CloudWatch::Alarm`, `aws_cloudwatch_metric_alarm`.

## Summary fields for evidence matching

Beyond existing fields (dashboards, alarms, log_groups, invocation_logging, evaluation_jobs, quota_management), the following enhanced fields are available in `ops-ex-summary.json`:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `xray.collected` / `xray.has_custom_rules` | GENOPS03_BP02 | X-Ray sampling rules indicate distributed tracing |
| `cloudwatch_metrics.has_token_metrics` | GENOPS02_BP02, GENSEC03_BP01 | InputTokenCount/OutputTokenCount published to CloudWatch |
| `cloudwatch_metrics.has_latency_metrics` | GENOPS02_BP02 | Latency/Duration metrics in AWS/Bedrock namespace |
| `eventbridge.has_bedrock_rules` / `eventbridge.rules_with_targets` | GENOPS02_BP02 | EventBridge rules for model/agent events |
| `sns.alarms_have_targets` | GENOPS02_BP02 | Alarms have SNS notification actions configured |
| `aws_config.recorder_active` | GENOPS04_BP01 | AWS Config recorder running for governance |

## Cross-pillar references

- `GENOPS01_BP01` ↔ `GENPERF01_BP01` (Performance ground truth) and `BP01_03` (AgentCore ground truth). Reference, then focus the Ops Excellence question on cadence and sampling.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENOPS01_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/model-evaluation.html |
| GENOPS01_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-cw.html |
| GENOPS02_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-cw.html |
| GENOPS02_BP02 | https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html |
| GENOPS02_BP03 | https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html |
| GENOPS03_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-management.html |
| GENOPS03_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/trace-events.html |
| GENOPS04_BP01 | https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_bedrock-readme.html |
| GENOPS04_BP02 | https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-projects.html |
| GENOPS05_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/custom-models.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Ops Excellence"
```
