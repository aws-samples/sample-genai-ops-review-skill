# Reliability Pillar Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-reliability.sh` → writes `$DATA_DIR/reliability-summary.json`.

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

10 IDs (`WA:Reliability` in `references/owned-checks.json`):

```
GENREL01_BP01, GENREL02_BP01, GENREL03_BP01, GENREL03_BP02,
GENREL04_BP01, GENREL04_BP02, GENREL05_BP01, GENREL05_BP02,
GENREL05_BP03, GENREL06_BP01
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENREL03_BP01`: retry/resilience — `retry`, `backoff`, `circuit`, `maxRetries`, `retryMode`, `CircuitBreaker`, `exponential`. Also covers the INVOCATION_RETRY_STRATEGY aspect — report under GENREL03_BP01.
- `GENREL03_BP02`: timeouts — `timeout`, `TimeoutInSeconds`, `maxDuration`, `idleSessionTTL`, `Timeout`.
- `GENREL02_BP01`: multi-AZ / redundant network — `availabilityZones`, `multi-az`, `SubnetIds` (multiple AZs). Cross-reference GENSEC01_BP02 (Security VPC endpoints).
- `GENREL04_BP01`: prompt versioning — `PromptVersion`, `prompt_version`, `prompt-template`. Cross-reference GENOPS03_BP01; focus on rollback capability.
- `GENREL05_BP01`: cross-region inference — `inference_profile`, `cross-region`, `failover`, `Route53`.

## Summary fields for evidence matching

Beyond existing fields (alarms, agent, flows, lambdas, inference_profiles, provisioned_throughput), the following enhanced fields are available in `reliability-summary.json`:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `step_functions.count` / `step_functions.has_agent_related` | GENREL03_BP01 | Step Functions for complex retry/recovery workflows |
| `route53.health_check_count` / `route53.has_failover` | GENREL02_BP01, GENREL05_BP01 | Route53 health checks and DNS failover |
| `autoscaling.bedrock_targets_count` | GENREL05_BP01 | Auto-scaling configured for Bedrock resources |
| `api_gateway.rest_api_count` | GENREL01_BP01 | API Gateway for request throttling |
| `network.multi_az` / `network.az_count` | GENREL02_BP01 | Multi-AZ subnet distribution for redundancy |

## Cross-pillar references

- `GENREL04_BP01` ↔ `GENOPS03_BP01` (prompt management). Reference; focus the reliability question on rollback.
- `GENREL02_BP01` ↔ `GENSEC01_BP02` (VPC endpoints). Reference; focus on redundancy/failover.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENREL01_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html |
| GENREL02_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/vpc-interface-endpoints.html |
| GENREL03_BP01 | https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html |
| GENREL03_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/agents-create.html |
| GENREL04_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-management.html |
| GENREL04_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html |
| GENREL05_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html |
| GENREL05_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html |
| GENREL05_BP03 | https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-regions.html |
| GENREL06_BP01 | https://docs.aws.amazon.com/sagemaker/latest/dg/distributed-training.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Reliability"
```
