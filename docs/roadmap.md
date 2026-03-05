# Auditor Roadmap

## Current State

Working alpha. The audit skill can download project files, inspect runs, and compare a human QA reviewer's log against app data. Pipeline mode works for vendor comparison but is used less frequently.

## Completed

- [x] TOC reconciliation pipeline (yours vs vendor)
- [x] OCR-based page content matching with similarity scores
- [x] Discrepancy report generation (CSV)
- [x] `download_project.rb` — fetch project files via GraphQL API
- [x] `inspect_run.rb` — inspect run summary and drill-down into step executions
- [x] `WorkflowClient` with HTTPS enforcement, auth header stripping, error sanitization
- [x] Config management (env vars + config file with permission checks)
- [x] HIPAA-aware audit logging and file permissions
- [x] Test coverage for API layer (WEBrick-based fakes)
- [x] Amy Smart case audit — completed, documented in `cases/Amy_Smart/audit_analysis.md`

## In Progress

- [ ] Valencia_Tiffany re-run (project 53, run 8564) — Letters Loop re-running with Medical Summary DOI prompt fix. Build Letters sort fix verified. ~8.5 hours, running overnight. After completion: verify DOI dates resolved, no regressions.

## Up Next

- [ ] Build "re-run from step N" feature — reset all executions for step N and downstream, then re-enqueue. Currently requires manual console script with FK-aware deletion order. Would save significant time on future partial re-runs.
- [ ] Parallel Letters Loop processing — no dependencies between iterations, would cut 8.5hr re-runs dramatically. Already on main app roadmap.

## Backlog

### Cleanup & Simplification
- [ ] Remove pandoc text-parsing fallback in `YoursTOCParser` — the `docx` gem handles DOCX parsing directly now, pandoc path is dead code for the primary use case
- [ ] Review `TheirsTOCParser` page cap (currently 500) — could silently drop valid pages for large vendor PDFs. Confirm max expected page count or make configurable
- [x] Add CLAUDE.md and keep roadmap updated

### Move to Main App
- [ ] Once audit workflow stabilizes, migrate API integration + audit logic into the Workflow Labs app as part of the report review feature
- [ ] This becomes a built-in QA tool rather than a separate CLI repo

### Testing
- [ ] Add tests for `download_project.rb` CLI (currently only `WorkflowClient` and `inspect_run.rb` have tests)
- [ ] Add tests for `simple_reconcile.rb` TOC comparison logic (end-to-end with sample data)

### Pipeline Improvements (lower priority — only when vendor comparison is needed)
- [ ] Improve OCR similarity scoring (current Jaccard similarity is basic)
- [ ] Handle multi-page records better in page matching
- [ ] Support vendor PDFs > 500 pages if needed
