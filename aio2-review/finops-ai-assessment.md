# FinOps for AI Assessment

Shared scaffolding lives in `${SKILL_ROOT}/references/framework-assessment-template.md`.

Check definitions (assessment metadata: `cli_commands`, `code_patterns`, `severity`): `${SKILL_ROOT}/references/finops-ai-checks.yaml`.

For canonical title, About text, and documentation URL of every check, run:

```bash
${SKILL_ROOT}/scripts/lens-lookup.sh --owner "FinOps:Understand" --owner "FinOps:Quantify Business Value" --owner "FinOps:Optimize" --owner "FinOps:Manage"
```
Assessment script: `${SKILL_ROOT}/scripts/finops-assessment.sh` → writes `$DATA_DIR/finops-summary.json`.

## Owned Check IDs

20 IDs across four domains (`FinOps:Understand`, `FinOps:Quantify Business Value`, `FinOps:Optimize`, `FinOps:Manage` in `references/owned-checks.json`):

```
FIN-UND-01, FIN-UND-02, FIN-UND-03, FIN-UND-04, FIN-UND-05,
FIN-QBV-01, FIN-QBV-02, FIN-QBV-03,
FIN-OPT-01, FIN-OPT-02, FIN-OPT-03, FIN-OPT-04,
FIN-OPT-05, FIN-OPT-06, FIN-OPT-07,
FIN-MGT-01, FIN-MGT-02, FIN-MGT-03, FIN-MGT-04, FIN-MGT-05
```

Maturity (Crawl/Walk/Run) and the canonical `interactive_question` come from the YAML; `build-findings-skeleton.sh` populates both into the JSONL skeleton.

## CLI fields consumed (from `finops-summary.json`)

- **Understand:** `understand.has_invocation_logging`, `understand.has_cost_data`, `understand.has_budgets`.
- **Optimize:** `optimize.has_guardrail_prefiltering`, `optimize.has_provisioned_throughput`.
- **Agent context:** `agent.model_id`, `agent.idle_session_ttl`.
- **Cost anomaly:** `cost_anomaly.collected`, `cost_anomaly.monitor_count`, `cost_anomaly.subscription_count` — serves FIN-MGT-03.
- **Cost tags:** `cost_allocation_tags.collected`, `cost_allocation_tags.active_count`, `cost_allocation_tags.has_ai_tags` — serves FIN-UND-01, FIN-UND-03.
- **Budgets (enhanced):** `budgets.collected`, `budgets.total_count`, `budgets.has_ai_budgets`, `budgets.alert_count` — serves FIN-MGT-01, FIN-MGT-02.

## Cross-pillar reference table

| FinOps check | Overlapping WA check | What to reference |
|---|---|---|
| FIN-OPT-01 (model right-sizing) | GENCOST01_BP01 | Model selection / right-sizing |
| FIN-OPT-02 (prompt optimization) | GENCOST03_BP01, GENCOST03_BP02 | Token-length optimization, max tokens |
| FIN-OPT-03 (prompt caching) | GENCOST03_BP03 | Caching configuration |
| FIN-OPT-05 (capacity commitment) | GENCOST02_BP01 | Provisioned vs on-demand |
| FIN-OPT-07 (content pre-filtering) | GENCOST03_BP04 | Guardrail pre-filtering |
| FIN-UND-02 (token tracking) | INVOCATION_LOGGING (Security) | Invocation logging for token capture |
| FIN-MGT-02 (budget controls) | BP09_03 (AgentCore) | Centralized cost monitoring |

## Checks without `interactive_question`

`FIN-OPT-01`, `FIN-OPT-03`, and `FIN-OPT-07` have `assessment_methods: ["code", "cloud"]` only. If both code and cloud assessment are inconclusive, mark them PENDING with a question derived from the YAML `description` field. `build-findings-skeleton.sh` falls back to a registry-title-based placeholder for these.

## Question batching

Group remaining interactive questions by domain (Understand → Quantify → Optimize → Manage) and present in batches with a skip option. Use the YAML's `interactive_question` text verbatim.
