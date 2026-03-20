# Auditor

Medical record review QA toolkit. Two modes of operation:

1. **Pipeline mode** — Compares our indexed record review (DOCX/PDF) against a vendor's indexed PDF. Runs locally via `bin/run_pipeline.rb`.
2. **Skill/agent mode** — Claude Code skill uses the API integration (`inspect_workflow.rb`, `inspect_run.rb`, `download_project.rb`) to audit a human QA reviewer's log against the app's run data and word output.

The skill mode is the primary active use case. Pipeline mode is used when we have a vendor file to compare against (less common).

## Architecture

```
lib/
  config.rb            — Reads credentials from env vars or ~/.config/auditor/config
  workflow_client.rb   — GraphQL HTTP client for Workflow Labs API
  cli_helpers.rb       — Shared CLI utilities (URL parsing, org resolution, error handling)
  summary_scorer.rb       — Medical Summary quality scoring engine (rubrics + checks)
  qa_reviewer.rb          — Automated QA review engine (DOS, content coverage, redundancy, provider checks)
  page_comparison.rb   — Shared page comparison (fingerprinting, similarity, OCR extraction)

bin/
  download_project.rb    — Fetches project files from Workflow Labs, sets up case directory
  inspect_run.rb         — Inspects a workflow run (summary + drill-down into step executions)
  inspect_workflow.rb    — Lists workflows or shows full workflow detail (steps, prompts, config)
  score_summaries.rb     — Scores Medical Summary quality for all letters in a run
  qa_review.rb             — Automated QA review for all letters in a run
  run_pipeline.rb        — Orchestrates the full vendor comparison pipeline (phases 1-4)
  simple_reconcile.rb    — TOC parsing and comparison (yours vs theirs)
  page_matcher.rb        — OCR-based page content matching
  extract_hyperlinks.py  — Extracts hyperlink-based page mappings from PDFs

  test_workflow_client.rb     — Unit tests for WorkflowClient (WEBrick fakes)
  test_inspect_run.rb         — Integration tests for inspect_run.rb CLI
  test_inspect_workflow.rb    — Integration tests for inspect_workflow.rb CLI
  test_score_summaries.rb     — Unit + integration tests for SummaryScorer and score_summaries.rb CLI
  test_qa_review.rb           — Unit + integration tests for QAReviewer and qa_review.rb CLI
  test_toc_parsers.rb         — Tests for TOC parsing logic
```

## Key Concepts

- **Case directory**: `cases/<CaseName>/` contains mappings, reports, ocr_cache for a case. Cases are gitignored (contain PHI).
- **Logical vs physical pages**: TOC references logical page numbers; hyperlink mappings convert these to physical PDF pages.
- **File Loop iterations**: 0-indexed in the app. Page 1 = iteration 0, page 124 = iteration 123.
- **Run inspection**: Summary mode shows step structure + execution counts. Drill-down mode shows full output/result/prompt for a specific step+iteration.
- **Iteration filtering**: `--iterations` accepts ranges (`10-25`) or comma-separated lists (`10,13,14,21`). Comma-separated lists fetch the enclosing range from the API and filter client-side.
- **Workflow inspection**: List mode finds workflows by name. Detail mode shows the full step pipeline with action configs (prompts, iterator settings, code templates).
- **Summary scoring**: Rule-based quality checks on Medical Summary outputs. Checks header format compliance (per subcategory template), date/provider consistency between header and letter metadata, empty content detection, required section presence, and content length ratios. Supports both document-first and old-pipeline runs. Output is a JSON scorecard with per-letter pass/fail and aggregate stats.
- **QA review**: Automated version of Xerses's manual QA process. Checks DOS verification (source page dates vs letter dates), content coverage (Extract Info findings reflected in summary), redundancy detection (overlapping pages or high text similarity), and provider data quality. Outputs JSON or CSV matching Xerses's QA log column format.

## Record Review Workflows

Two workflow types are supported for record review:

- **Record Review** (old pipeline) — File Loop over run files, per-page Extract Info/Extract Output with continuation flags, Build Letters code step, Letters formatter step. Uses `RunDocument::RecordReview` to assemble letters from execution results.
- **Record Review Batch** (document-first) — File Loop over `_document.pages`, `DocumentSplitService` creates Letters on the Document model, metadata synced to pages. Iterator steps may use `batchSize`, `concurrent`, and `concurrency` fields.

The CLI auto-detects the workflow type based on whether the run has a `document` association (via the `documentable` field). Old-pipeline features (continuation analysis, Build Letters inspection) remain fully functional.

## HIPAA Considerations

- Downloaded files are `chmod 0600` (owner-only)
- Audit log at `~/.config/auditor/access.log` records project IDs only, never filenames or case names
- Error messages are truncated to avoid leaking PHI
- HTTPS enforced for all non-localhost connections
- Config file permissions are checked (warns if > 0600)

## Commands

```bash
# Run tests
ruby bin/test_workflow_client.rb
ruby bin/test_inspect_run.rb
ruby bin/test_inspect_workflow.rb
ruby bin/test_score_summaries.rb
ruby bin/test_toc_parsers.rb
ruby bin/test_qa_review.rb

# List workflows / inspect a workflow
bin/inspect_workflow.rb                                        # List all workflows
bin/inspect_workflow.rb --query "Record Review"                # Search by name
bin/inspect_workflow.rb <workflow_id>                           # Full detail (flattened action configs)
bin/inspect_workflow.rb <workflow_id> --step "Extract info"     # Single step detail
bin/inspect_workflow.rb <workflow_id> -o /tmp/workflow.json     # Save to file

# Download a project's files
bin/download_project.rb <project_id> [--org "Name"]
bin/download_project.rb --list-orgs

# Inspect a run
bin/inspect_run.rb <run_id>                                               # Summary (auto-detects workflow type)
bin/inspect_run.rb <run_id> --step "Extract Info" --iteration 5           # Drill-down
bin/inspect_run.rb <run_id> --step "Extract Info" --stats                 # Aggregate analysis
bin/inspect_run.rb <run_id> --step "Extract Info" --summary               # Compact overview
bin/inspect_run.rb <run_id> --step "Extract Info" --where "date=Unknown"  # Filter by result field
bin/inspect_run.rb <run_id> --step "Extract Info" --fields date,thoughts  # Select result fields
bin/inspect_run.rb <run_id> --letters                                     # Letter details (batch runs)
bin/inspect_run.rb <run_id> --pages                                       # Page metadata (batch runs)
bin/inspect_run.rb <run_id> -o /tmp/run.json                              # Save to file

# Score Medical Summary quality for a run
bin/score_summaries.rb <run_id>                           # Full scorecard (JSON)
bin/score_summaries.rb <run_id> --compact                  # Summary + flagged letters only
bin/score_summaries.rb <run_id> --compact --errors-only    # Errors only (skip warnings)
bin/score_summaries.rb <run_id> -o /tmp/scores.json        # Save to file

# Automated QA review for a run
bin/qa_review.rb <run_id>                               # Full JSON report
bin/qa_review.rb <run_id> --compact                      # Flagged findings only
bin/qa_review.rb <run_id> --format csv                   # CSV (Xerses's QA log format)
bin/qa_review.rb <run_id> --format csv -o /tmp/qa.csv    # Save CSV to file

# Run full vendor comparison pipeline
bin/run_pipeline.rb --case "LastName_FirstName" <yours.docx> <theirs.pdf>
```

## Auth Setup

```bash
export WORKFLOW_API_TOKEN=<token>
export WORKFLOW_ORG_ID=<org_id>
# Or add to ~/.config/auditor/config (key=value format)
```

## Tech Stack

- Ruby 3.x (primary language)
- Python 3.x (hyperlink extraction only)
- Minitest + WEBrick for testing
- External tools: mutool, tesseract, pandoc (pipeline mode only)
- `docx` gem for DOCX table parsing

## Code Style

- `frozen_string_literal: true` on all Ruby files
- Classes with `initialize` + `run` pattern for CLI scripts
- Tests use WEBrick fakes (no mocking libraries)
- No Rails dependencies — this is a standalone repo

## Docs

```
docs/
  roadmap.md    — Product direction, completed work, backlog (single source of truth)
```

- `docs/roadmap.md` is the single roadmap doc. All backlog items belong there, not in standalone files.
- Case-specific audit findings go in `cases/<CaseName>/audit_analysis.md` (gitignored with the rest of the case).
- Do not put patient names, DOBs, or other PHI in docs — they are version controlled.

## Future Direction

This is an early alpha. Once the audit workflow stabilizes, the API integration and audit logic will move into the main Workflow Labs app as part of the report review feature.
