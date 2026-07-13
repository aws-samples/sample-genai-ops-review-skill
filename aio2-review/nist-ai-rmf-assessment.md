# NIST AI RMF Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/framework-assessment-template.md`.

Check definitions (assessment metadata: `cli_commands`, `code_patterns`, `severity`): `${SKILL_ROOT}/references/nist-ai-rmf-checks.yaml`.

For canonical title, About text, and documentation URL of every check, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "NIST:Govern" --owner "NIST:Map" --owner "NIST:Measure" --owner "NIST:Manage"
```
Assessment script: `${SKILL_ROOT}/scripts/nist-assessment.sh` → writes `$DATA_DIR/nist-summary.json`.

## Owned Check IDs

37 IDs across four functions (`NIST:Govern`, `NIST:Map`, `NIST:Measure`, `NIST:Manage` in `references/owned-checks.json`):

```
GOVERN-1.1, GOVERN-1.2, GOVERN-1.3, GOVERN-1.4, GOVERN-1.5, GOVERN-1.6, GOVERN-1.7,
GOVERN-2.1, GOVERN-2.2, GOVERN-2.3, GOVERN-4.3, GOVERN-6.1, GOVERN-6.2,
MAP-1.1, MAP-1.6, MAP-2.1, MAP-2.2, MAP-3.5, MAP-4.1, MAP-5.1,
MEASURE-1.1, MEASURE-2.1, MEASURE-2.4, MEASURE-2.6, MEASURE-2.7, MEASURE-2.9,
MEASURE-2.10, MEASURE-2.11, MEASURE-2.12, MEASURE-3.1,
MANAGE-1.1, MANAGE-1.3, MANAGE-2.2, MANAGE-2.4, MANAGE-3.2, MANAGE-4.1, MANAGE-4.3
```

## CLI fields consumed (from `nist-summary.json`)

- **Govern:** `govern.has_guardrails`, `govern.has_invocation_logging`.
- **Map:** `map.has_custom_models`, `map.has_vpc_endpoints`.
- **Measure:** `measure.has_alarms`, `measure.has_agent_aliases`.
- **Manage:** `manage.has_iam_policies`, `manage.role_count`.

CLI fields are evidence, not definitive PASS/FAIL. Confirm with the canonical `interactive_question` from the YAML when a field is missing or ambiguous.

## Cross-pillar reference table

| NIST check | Overlapping WA check | What to reference |
|---|---|---|
| MEASURE-2.6 (safety) | RAI_SAFETY, GENSEC02_BP01 | Guardrail config and safety thresholds |
| MEASURE-2.7 (security) | GENSEC05_BP01, GENSEC01_BP02 | IAM least privilege, VPC endpoints |
| MEASURE-2.10 (privacy) | RAI_PRIVACY | PII handling, encryption |
| MEASURE-2.11 (fairness) | RAI_FAIRNESS | Bias testing |
| MEASURE-2.9 (explainability) | RAI_EXPLAINABILITY | Traces, attribution |
| MEASURE-2.4 (monitoring) | GENOPS02_BP01, GENOPS02_BP02 | Dashboards, alarms |
| GOVERN-4.3 (testing) | BP08_01, GENPERF01_BP01 | Test suites, ground truth |
| GOVERN-6.2 (contingency) | GENREL03_BP01 | Retry, fallback, circuit breaker |
| MANAGE-2.4 (deactivation) | RAI_CONTROLLABILITY | Kill switch, HITL |
| MANAGE-4.1 (post-deploy) | LC_CONTINUOUS_IMPROVEMENT | Monitoring, feedback |

## Question batching

Group remaining interactive questions by function (Govern → Map → Measure → Manage) and present them in batches with a skip option. Use the YAML's `interactive_question` text verbatim — `build-findings-skeleton.sh` emits these in the JSONL skeleton already.
