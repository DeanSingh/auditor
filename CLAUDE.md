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

bin/
  download_project.rb    — Fetches project files from Workflow Labs, sets up case directory
  inspect_run.rb         — Inspects a workflow run (summary + drill-down into step executions)
  inspect_workflow.rb    — Lists workflows or shows full workflow detail (steps, prompts, config)
  run_pipeline.rb        — Orchestrates the full vendor comparison pipeline (phases 1-4)
  simple_reconcile.rb    — TOC parsing and comparison (yours vs theirs)
  page_matcher.rb        — OCR-based page content matching
  extract_hyperlinks.py  — Extracts hyperlink-based page mappings from PDFs

  test_workflow_client.rb     — Unit tests for WorkflowClient (WEBrick fakes)
  test_inspect_run.rb         — Integration tests for inspect_run.rb CLI
  test_inspect_workflow.rb    — Integration tests for inspect_workflow.rb CLI
  test_toc_parsers.rb         — Tests for TOC parsing logic
```

## Key Concepts

- **Case directory**: `cases/<CaseName>/` contains mappings, reports, ocr_cache for a case. Cases are gitignored (contain PHI).
- **Logical vs physical pages**: TOC references logical page numbers; hyperlink mappings convert these to physical PDF pages.
- **File Loop iterations**: 0-indexed in the app. Page 1 = iteration 0, page 124 = iteration 123.
- **Run inspection**: Summary mode shows step structure + execution counts. Drill-down mode shows full output/result/prompt for a specific step+iteration.
- **Workflow inspection**: List mode finds workflows by name. Detail mode shows the full step pipeline with action configs (prompts, iterator settings, code templates).

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
ruby bin/test_toc_parsers.rb

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
bin/inspect_run.rb <run_id>                                               # Summary
bin/inspect_run.rb <run_id> --step "Extract Info" --iteration 5           # Drill-down
bin/inspect_run.rb <run_id> --step "Extract Info" --stats                 # Aggregate analysis
bin/inspect_run.rb <run_id> --step "Extract Info" --summary               # Compact overview
bin/inspect_run.rb <run_id> --step "Extract Info" --where "date=Unknown"  # Filter by result field
bin/inspect_run.rb <run_id> --step "Extract Info" --fields date,thoughts  # Select result fields
bin/inspect_run.rb <run_id> -o /tmp/run.json                              # Save to file

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
