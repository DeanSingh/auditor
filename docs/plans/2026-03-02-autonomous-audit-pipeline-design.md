# Autonomous Audit Pipeline

**Date**: 2026-03-02
**Status**: Approved

## Problem

The `/audit` skill requires manual file preparation:
1. Download medical summary DOCX and vendor PDF from Workflow Labs (workflow.ing)
2. Export QA reviewer notes from Google Sheets as CSV
3. Place files in the correct case directory structure
4. Then run the audit

This manual setup breaks Claude Code's ability to run an end-to-end autonomous audit.

## Solution

Build a CLI download script (`bin/download_project.rb`) and update the `/audit` skill so Claude Code can go from "audit project 50" to a complete analysis autonomously.

**Google Sheets**: QA reviewer CSV will continue to be exported manually and placed in the case directory before running `/audit`.

## Architecture: CLI Scripts + Skill Orchestration

CLI scripts in `bin/`, orchestrated by the `/audit` skill. No MCP server.

**Why CLI over MCP:**
- The auditor is already CLI-based (run_pipeline.rb, investigate.rb, etc.)
- Sequential workflow (download → setup → run → analyze) doesn't benefit from MCP's ad-hoc tool model
- Output needs to be files on disk — MCP tools return JSON, which adds an awkward translation layer
- Simpler to build, debug, and maintain

## Components

### 1. `bin/download_project.rb`

CLI script that downloads project files from Workflow Labs via GraphQL API.

**Usage:**
```bash
bin/download_project.rb <project_id> [--case "Case_Name"] [--base-url "https://workflow.ing"]
```

**Behavior:**
1. Authenticate with Workflow Labs GraphQL API (Bearer token)
2. Query project data:
   ```graphql
   query GetProject($id: ID!) {
     project(id: $id) {
       id
       name
       claimantDob
       documents {
         id
         name
         status
         kind
         file { filename url bytesize type }
       }
       runs {
         id
         status
         started
         finished
         workflow { id name }
         files { filename url bytesize type }
         inputFiles { filename url bytesize type }
       }
     }
   }
   ```
3. Auto-detect case name from project name or COMPLETE PDF filename (override with `--case`)
4. Download files:
   - **Run output files** → `medical_summary_indexed.docx` (or similar)
   - **Project documents** → `COMPLETE_<Name>_<N>.pdf` (vendor records)
5. Set up case directory:
   ```
   cases/<Case_Name>/
   ├── medical_summary_indexed.docx   # from latest successful run outputs
   ├── COMPLETE_<Name>_<N>.pdf        # from project documents
   └── (QA log CSV)                   # manually placed by user
   ```
6. Print summary of what was downloaded and where

**File identification heuristics:**
- Run output files with `.docx` extension containing "medical_summary" or "indexed" → your indexed document
- Project documents with `COMPLETE_` prefix or `.pdf` extension → vendor document
- If ambiguous, download all and let the user/skill sort it out

**Error handling:**
- Missing/expired auth token → clear error with instructions to create one
- Project not found → error with project ID
- Download failures → retry once, then report which files failed
- No runs with output files → warn but still download documents

### 2. Auth Configuration

**One-time setup** (done in Rails console):

```ruby
# In Workflow Labs Rails console
user = User.find_by(email: "dean@...")
auth = Authentication.create!(user: user, ip: "127.0.0.1")
puts auth.token  # → copy this token
```

**Token storage:**
- Primary: `WORKFLOW_API_TOKEN` environment variable
- Fallback: `~/.config/auditor/token` file (plain text, chmod 600)
- Script checks env var first, then file

Also needs `WORKFLOW_ORG_ID` for the `X-ORGANIZATION-ID` header:
- Same storage pattern (env var + file fallback)
- Can be stored alongside token in `~/.config/auditor/config`:
  ```
  token=<api_token>
  org_id=<organization_id>
  base_url=https://workflow.ing
  ```

### 3. Updated `/audit` Skill

Add "Step 0: Project Download" before existing Step 1:

```markdown
## Step 0: Project Download (if project ID or URL provided)

If `$ARGUMENTS` contains a project ID (number) or workflow.ing URL:

1. Extract the project ID from the argument
   - Number: use directly (e.g., "50")
   - URL: extract from path (e.g., "https://workflow.ing/dashboard/projects/50" → 50)
2. Run: `bin/download_project.rb <project_id>`
3. Read the script output to identify the case name and downloaded files
4. Continue to Step 1 with the case name

If `$ARGUMENTS` is a case name (not a number/URL), skip to Step 1.
```

Also update the skill to support two modes:

**Full reconciliation mode** (default when both yours + vendor files exist):
- Step 0 → Step 1-4 (existing pipeline) → Step 5 (analysis)
- Optionally includes QA comparison if CSV present

**QA-only mode** (when user says "QA only" or only QA CSV + yours exist):
- Step 0: Download project files
- Skip Steps 1-4 (no vendor comparison needed)
- Jump to Step 2b: QA Log Comparison
- Compare QA reviewer notes against AI record review output

### 4. File Download Mechanics

Workflow Labs serves files via Active Storage. The GraphQL `url` field returns a Rails blob URL:
```
https://workflow.ing/rails/active_storage/blobs/redirect/{signed_id}/{filename}
```

Download flow:
1. GraphQL query returns blob URLs
2. HTTP GET the blob URL with `Authorization: Bearer <token>` header
3. Rails redirects (302) to a presigned S3 URL (in production) or serves directly (in dev)
4. Follow the redirect to download the actual file
5. Save to the case directory with the original filename

**Implementation:** Use Ruby's `net/http` with redirect following, or `open-uri`, or shell out to `curl -L`.

## Data Flow

```
User: "/audit 50"
  │
  ├─→ Skill extracts project ID: 50
  │
  ├─→ Step 0: bin/download_project.rb 50
  │     ├─→ POST https://workflow.ing/graphql
  │     │     Authorization: Bearer <token>
  │     │     X-ORGANIZATION-ID: <org_id>
  │     │     Body: { query: "...", variables: { id: "50" } }
  │     │
  │     ├─→ Response: project name, documents[], runs[].files[]
  │     │
  │     ├─→ Download medical_summary_indexed.docx (from run outputs)
  │     ├─→ Download COMPLETE_Reed_Eric_10.pdf (from documents)
  │     └─→ Setup cases/Reed_Eric/
  │
  ├─→ (User optionally drops QA CSV into cases/Reed_Eric/)
  │
  ├─→ Mode detection:
  │     ├─→ Both yours + vendor files → Full reconciliation (Steps 1-4, then analysis)
  │     └─→ Only yours + QA CSV → QA-only mode (skip to Step 2b)
  │
  └─→ Analysis output: discrepancy_report.csv + QA comparison
```

## What We're NOT Building

- No MCP server
- No Google Sheets API integration (manual CSV export)
- No changes to the Workflow Labs app (consuming existing GraphQL API)
- No new REST endpoints
- No browser automation or scraping

## Implementation Notes

- Script language: Ruby (consistent with existing `bin/` scripts)
- Dependencies: `net/http`, `json`, `fileutils` (stdlib only — no new gems)
- The script should be idempotent: re-running with the same project ID overwrites existing files
- Add `~/.config/auditor/` to `.gitignore` documentation (contains secrets)
- Add Bash permissions for the new script to `.claude/settings.local.json`
