# report.json schema

Single source of truth for an AIO2 review. Created by `discover-resources.sh`; updated by the orchestrator via three helpers (`merge-findings.sh`, `set-narrative.sh`); consumed by `generate-report.sh` to produce `report.md` and `report.html`. The agent never edits `report.json` directly.

Every closed set in this schema is enforced by `validate-report.sh`. Any value outside the closed set is rejected and the script exits non-zero before any report is generated.

## Top-level shape

```json
{
  "metadata":          { ... },
  "executive_summary": { ... },
  "findings":          [ { ... }, ... ]
}
```

## `metadata`

```json
{
  "solution_name":     "string",
  "region":            "string",
  "account_id":        "string",
  "profile":           "string (or 'default')",
  "identity_arn":      "string",
  "input_type":        "Agent ARN | CloudFormation Stack | AppRegistry Application | Code Workspace",
  "resources_summary": "string (e.g. '1 Bedrock Agent, 2 Knowledge Bases')",
  "models":            ["string"],
  "review_date":       "YYYY-MM-DD",
  "review_scope":      "Code Review | Cloud Review | Full Review",
  "frameworks":        ["WA","NIST","FinOps"]
}
```

`frameworks` drives validation: the registry is filtered to checks whose `frameworks` array intersects this list, and that filtered set defines the universe of expected `check_id`s.

## `executive_summary`

```json
{
  "prose":                   "string (3 paragraphs separated by \\n\\n: 1/Solution overview 2/Key strengths 3/Top 5-8 Critical/High findings)",
  "strengths":               ["string", ...],
  "critical_high_findings":  ["string", ...]
}
```

`prose` MUST contain exactly 3 paragraphs separated by `\n\n` (double newline). The renderer splits on `\n\n` to produce separate `<p>` blocks in HTML and separate paragraphs in markdown. A single block without `\n\n` separators renders as one paragraph. The three paragraphs are: (1) overall solution details, (2) key strengths, (3) top 5–8 critical/high findings. Each paragraph should be 5–8 sentences. `strengths` and `critical_high_findings` arrays are retained in the JSON for programmatic access but are NOT rendered as separate sections — their content should be incorporated into prose paragraphs 2 and 3 respectively.

## `findings[]`

One entry per `check_id`. Every check that the active frameworks own MUST appear exactly once.

```json
{
  "check_id": "string (must exist in references/check-registry.json)",
  "status":   "PASS | FAIL | PARTIAL | N/A | PENDING",
  "method":   "auto | code | interactive | cross-ref | needs-input",
  "source":   "dynamic:<filename>     // optional, only this form is valid",
  "maturity": "Crawl | Walk | Run     // optional, FinOps only",

  "finding":        "string  // required for PASS, FAIL, PARTIAL",
  "remediation":    "string  // required for FAIL, PARTIAL",
  "doc_url":        "string  // optional; rendered after remediation",
  "question":       "string  // required for PENDING",
  "why_it_matters": "string  // optional, PENDING only",
  "reason":         "string  // required for N/A",

  "steps": [
    { "index": 0, "status": "PASS | FAIL | PARTIAL | N/A | PENDING", "applicable": true, "evidence": "string" }
  ]   // optional; present only for child checks that define implementation_steps
}
```

Field-by-field rules:

- `check_id` — must exist in the registry. Unregistered IDs are rejected.
- `status` — closed set above. Default `method` is `needs-input` when `status=PENDING`, otherwise `auto`.
- `method` — closed set above.
- `source` — optional. Only `dynamic:<filename>` is accepted; filename matches `[A-Za-z0-9._-]+`.
- `maturity` — optional. FinOps maturity tiers only.
- Required-field-by-status:
  - `PASS`     → `finding`
  - `FAIL`     → `finding` + `remediation` (`doc_url` recommended)
  - `PARTIAL`  → `finding` + `remediation` (`doc_url` recommended)
  - `PENDING`  → `question` (`why_it_matters` optional)
  - `N/A`      → `reason`
- Manual-input guard: a check whose registry entry has `requires_user_input: true` cannot be resolved from CLI or code — only a human can answer it. Such a finding may hold a non-`PENDING` status **only** when `method` is `interactive` (the user answered) or `cross-ref` (a WA finding already covered it). Any other method (`auto`, `code`, `needs-input`) with a non-`PENDING` status is rejected by `merge-findings.sh` and `validate-report.sh`. If no answer was collected, leave the check `PENDING` with `method: "needs-input"` — never silently mark it PASS/FAIL/PARTIAL/N/A.
- `steps[]` — optional. Present only for child checks that define `implementation_steps` (in `references/wa-implementation-guidance.json`). Each entry: `index` (integer, positional), `status` (closed 5-value set: `PASS`/`FAIL`/`PARTIAL`/`N/A`/`PENDING`), `applicable` (boolean — `false` when the step's service is absent from the workload), `evidence` (string). When `steps[]` is present and non-empty, the finding's `status` is DERIVED from the steps by `merge-findings.sh` (the agent does not hand-set it). Findings without `steps[]` keep their agent-set status.

## Coverage rule

`validate-report.sh` builds the expected `check_id` set from the registry filtered by `metadata.frameworks` and verifies:

- every expected `check_id` appears exactly once in `findings[]`,
- no duplicate `check_id`s,
- no unregistered `check_id`s.

The check count is computed dynamically from registry × frameworks. There is no hard-coded total.

## File ownership

| Writer                         | Section it owns                                  |
|--------------------------------|--------------------------------------------------|
| `discover-resources.sh`        | initial `metadata`, empty other sections         |
| `merge-findings.sh`            | `findings[]` (atomic batch append/replace)       |
| `set-narrative.sh`             | `executive_summary.*`, `metadata.review_scope`   |
| `generate-report.sh`           | reads everything, writes `report.md` + `report.html` |

Each helper takes an exclusive lock on `report.json` for its update. The agent never edits `report.json` directly.
