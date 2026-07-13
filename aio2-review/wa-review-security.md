# Security Pillar Assessment

Shared workflow scaffolding lives in `${SKILL_ROOT}/references/wa-pillar-template.md`.

Pillar script: `${SKILL_ROOT}/scripts/wa-security.sh` → writes `$DATA_DIR/security-summary.json`.

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

Produce findings for exactly these 10 `check_id`s (from `references/owned-checks.json` → `WA:Security`). Use these IDs EXACTLY in any prose; do NOT abbreviate, rename, or invent IDs.

```
GENSEC01_BP01, GENSEC01_BP02, GENSEC01_BP03, GENSEC01_BP04,
GENSEC02_BP01, GENSEC03_BP01, GENSEC04_BP01, GENSEC04_BP02,
GENSEC05_BP01, GENSEC06_BP01
```

## Code inspection (if `CODE_ACCESS = true`)

- `GENSEC04_BP02`: input sanitization — search for `sanitize`, `validate`, `filter`, `escape`.
- `GENSEC05_BP01`: user confirmation flows — search for `confirm`, `approval`, `userConfirmation`.

## Summary fields for evidence matching

Beyond existing fields (guardrails, iam_roles, cloudtrail, vpc_endpoints, cognito, invocation_logging, prompt_catalog, session_isolation, agentcore_policy, knowledge_bases), the following enhanced fields are available in `security-summary.json`:

| Field | Serves Check(s) | Meaning |
|-------|-----------------|---------|
| `org_scps.collected` / `org_scps.has_bedrock_restrictions` | GENSEC01_BP01, GENSEC05_BP01 | Organization SCPs restricting Bedrock model access |
| `org_scps.policies[].has_bedrock_deny` | GENSEC01_BP01 | Per-SCP bedrock deny statements |
| `vpc_endpoint_security_groups.endpoints[].restricted` | GENSEC01_BP02 | VPC endpoint SGs restrict ingress (no 0.0.0.0/0) |
| `guardduty.enabled` / `guardduty.data_sources` | GENSEC03_BP01 | GuardDuty threat detection active with data sources |
| `waf.web_acl_count` / `waf.has_rate_limit_rules` | GENSEC04_BP02 | WAF ACLs providing rate limiting |

## Cross-pillar references

None for Security. This pillar is evaluated independently.

## Remediation Links

| Check | Documentation |
|-------|--------------|
| GENSEC02_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html |
| GENSEC05_BP01 | https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html |
| GENSEC01_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/vpc-interface-endpoints.html |
| GENSEC03_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/logging-using-cloudtrail.html |
| GENSEC04_BP02 | https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-content-filters.html |
| GENSEC06_BP01 | https://docs.aws.amazon.com/bedrock/latest/userguide/custom-models.html |

For the canonical title, About text, and documentation URL of every check listed above, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "WA:Security"
```
