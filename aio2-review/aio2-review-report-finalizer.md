# Report Finalization

Step 11 calls `${SKILL_ROOT}/scripts/generate-report.sh`, which reads `${DATA_DIR}/report.json` and the registry and produces both `report.md` and `report.html`. Before generating, fill in the three narrative slots via `set-narrative.sh`.

## Generate first-draft narrative

After all framework batches have been merged, run:

```bash
${SKILL_ROOT}/scripts/draft-narrative.sh --data-dir "$DATA_DIR"
```

This writes two first-draft files under `$DATA_DIR/_work/drafts/`:

- `exec-critical.txt` — top FAIL/PARTIAL findings ordered HIGH → MEDIUM → LOW, with check_id, title, and a 200-character excerpt.
- `exec-strengths.txt` — every PASS finding, one per line, summarized.

Edit these in place (or copy + edit) to add prose framing and collapse cross-ref cascades. Then feed each one into `set-narrative.sh --text-file`.

## Inject narrative content

Closed sets and field-by-status rules live in SKILL.md → "Helper Closed Sets". Never edit `report.json` directly.

```bash
${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section exec-prose \
  --text-file "$DATA_DIR/_work/drafts/exec-prose.txt"

${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section exec-strengths \
  --text-file "$DATA_DIR/_work/drafts/exec-strengths.txt"

${SKILL_ROOT}/scripts/set-narrative.sh --data-dir "$DATA_DIR" --section exec-critical \
  --text-file "$DATA_DIR/_work/drafts/exec-critical.txt"
```

**Note:** The `exec-strengths` and `exec-critical` arrays are retained in `report.json` for programmatic access but are NOT rendered as separate report sections. Their content should be woven into the `exec-prose` paragraphs 2 and 3 respectively. The rendered report shows only the unified 3-paragraph Executive Summary.

Author `exec-prose.txt` yourself (the agent's job — it is the only narrative file `draft-narrative.sh` does not pre-populate). The prose MUST be exactly 3 paragraphs separated by blank lines (which become `\n\n` in the JSON). Each paragraph should be 5–8 sentences:

**Paragraph 1 — Solution Overview:** What the solution does, its structure, key components (models, agents, knowledge bases, guardrails), deployment model, and integration points. Set the scene for the reader.

**Paragraph 2 — Key Strengths:** What the solution does well — highlight specific PASS findings across security, reliability, operations, cost management, agentic patterns, and responsible AI. Be concrete (name the patterns, services, and configurations that are working).

**Paragraph 3 — Top Critical/High Findings:** The 5–8 most impactful gaps requiring immediate attention. Name specific check IDs and their implications. Start with the single most critical finding, then list secondary priorities. End with the overall risk posture.

**IMPORTANT:** These MUST be separate paragraphs (separated by a blank line in the text file). Do NOT combine them into a single paragraph. The renderer splits on `\n\n` to produce separate `<p>` tags in HTML. A single block of text will render as one wall of text.

`exec-strengths` / `exec-critical`: one item per non-blank line; `- ` is added by the renderer. `exec-prose`: paragraphs separated by blank lines.

## PENDING count consistency

State the PENDING count in the prose to match `validate-report.sh`'s coverage check: count `findings[]` entries with `status == "PENDING"`. The Auto-Assessment Summary table and Checks Requiring Human Input table are derived from the same JSON, so the numbers always agree.

## Generate

```bash
${SKILL_ROOT}/scripts/generate-report.sh \
  --data-dir "$DATA_DIR" \
  --template "${SKILL_ROOT}/references/report-finalizer-template.html"
```

Refuses to run unless `validate-report.sh` passes (every active-framework check_id present, no duplicates, every closed-set value valid, every required narrative present per status). Fix any reported failures with `merge-findings.sh --replace` for findings, or `set-narrative.sh` for narrative gaps, then re-run.

## Severity Levels

- **CRITICAL** — Must fix immediately; security or data exposure risk
- **HIGH** — Should fix soon; significant operational or reliability gap
- **MEDIUM** — Plan to address; optimization opportunity
- **LOW** — Nice to have; sustainability or organizational improvement

## Rules

- Never call `fsWrite`/`fsAppend` against `report.json`, `report.md`, or `report.html` — the helpers and the renderer are the only writers.
- `set-narrative.sh` accepts `--text`, `--text-file`, or `--json` — exactly one. Passing multiple is an error.
- **`--section exec-prose` MUST use `--text-file`** (the script rejects `--text` for this section). Multi-line content loses newlines when passed as inline shell arguments. Always write to a file first (e.g., `$DATA_DIR/_work/drafts/exec-prose.txt`), then pass via `--text-file`.
- `generate-report.sh` is purely declarative over `report.json`; there is no `--force` mode. To rebuild any section, change the underlying JSON via `merge-findings.sh --replace` or `set-narrative.sh` and re-run.
