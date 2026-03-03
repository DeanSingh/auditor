# Inspect Run CLI — Design

**Goal:** Replace browser-based run inspection with a CLI command so the auditor agent can query workflow structure and step execution data via GraphQL instead of navigating the UI.

**Problem:** The auditor agent currently opens the browser to check run execution details (date reasoning in Extract Info, content in Medical Summary, prompt instructions). This is slow — it renders React, waits for Apollo queries, then scrapes the UI. The same data is available via GraphQL.

**Context:** Run sizes range from 2 to 10,795 executions. The largest run (8564) has ~67 MB of execution output+result data. Fetching everything at once is not viable.

---

## Architecture: Two-tier inspect command

A single new script — `bin/inspect_run.rb` — with two modes:

### Summary mode (no `--step`)

```
bin/inspect_run.rb 8564
bin/inspect_run.rb https://workflow.ing/dashboard/runs/8564
```

Returns the workflow structure and execution overview:
- Run metadata (id, status, started, finished)
- Workflow name and step list (name, action type, priority)
- Per-step execution counts and statuses (fetched as lightweight id+status+step_name, grouped client-side)
- Run-level stats (total executions, step count, failed count)
- Prompt templates for Prompt-type steps (Extract Info, Medical Summary instructions)

**Payload:** ~400 KB for a 10K-execution run (only id, status, step name per execution — no output/result data).

### Drill-down mode (`--step` + optional `--iteration`/`--iterations`)

```
bin/inspect_run.rb 8564 --step "Extract Info" --iteration 123
bin/inspect_run.rb 8564 --step "Extract Info" --iterations 99-123
```

Returns full execution data for the specified step and iteration range:
- output, result, prompt, status, started, finished
- step name for verification

Uses the existing `ExecutionFilterInput` on the GraphQL API — supports `stepName`, `iteration`, `iterationMin`, `iterationMax`.

## Input parsing

Accepts run ID as:
- Bare number: `8564`
- Full URL: `https://workflow.ing/dashboard/runs/8564`

Parsed via regex: `arg =~ %r{/runs/(\d+)}` or `/\A\d+\z/`.

Flags:
- `--step NAME` — step name to drill into
- `--iteration N` — single iteration
- `--iterations N-M` — iteration range
- `--org NAME` — organization name (same as download_project.rb)
- `--base-url URL` — override base URL

## Output format

JSON to stdout. The agent is the primary consumer, not a human.

**Summary:**
```json
{
  "run": { "id": "8564", "status": "SUCCEEDED", "started": "...", "finished": "..." },
  "workflow": {
    "name": "Record Review",
    "steps": [
      {
        "name": "Extract Info",
        "action_type": "Action::Prompt",
        "execution_count": 1874,
        "succeeded": 1874,
        "failed": 0,
        "prompt_template": "USER: Given the following page..."
      }
    ]
  },
  "stats": { "execution_count": 10795, "step_count": 28, "failed_execution_count": 0 }
}
```

**Drill-down:**
```json
{
  "step": "Extract Info",
  "executions": [
    {
      "iteration": 123,
      "status": "SUCCEEDED",
      "output": "Date: Unknown\nDate Type: ...\nThoughts: ...",
      "result": { "date": "Unknown", "thoughts": "..." }
    }
  ]
}
```

## GraphQL queries

Two new queries in `WorkflowClient`. No Rails-side changes needed — the existing schema and `ExecutionFilterInput` already support everything.

**Summary query:**
```graphql
query InspectRun($id: ID!) {
  run(id: $id) {
    id
    status
    started
    finished
    stats { executionCount stepCount failedExecutionCount succeededExecutionCount }
    workflow {
      name
      steps {
        id name priority
        action { ... on PromptAction { messages { role template } } }
      }
    }
    executions {
      id
      status
      step { name }
    }
  }
}
```

The `executions` field returns only id, status, and step name — no output/result. The CLI groups by step name client-side to produce per-step counts.

**Drill-down query:**
```graphql
query InspectRunExecutions($id: ID!, $filter: ExecutionFilterInput) {
  run(id: $id) {
    executions(filter: $filter) {
      iteration
      status
      output
      result
      prompt
      step { name }
      started
      finished
    }
  }
}
```

Filter variables example: `{ stepName: "Extract Info", iterationMin: 99, iterationMax: 123 }`.

## SKILL.md changes

- **New Step 0.5:** After downloading, run `bin/inspect_run.rb <run_id>` in summary mode to orient. Agent sees workflow structure, step counts, and prompt templates before analysis.
- **Step 2c (Date Reasoning):** Replace browser navigation with `bin/inspect_run.rb <run_id> --step "Extract Info" --iteration <N>`.
- **Step 2d (Content Verification):** Replace browser navigation with `bin/inspect_run.rb <run_id> --step "Medical Summary" --iteration <N>`. Prompt instructions come from summary mode output.
- **Browser fallback:** Stays in the skill for anything the CLI doesn't cover (e.g., Report Review left panel).

## Implementation scope

- **New file:** `bin/inspect_run.rb` (~200 lines)
- **Modified file:** `lib/workflow_client.rb` — add two new queries and `fetch_run`/`fetch_run_executions` methods
- **Modified file:** `~/.claude/skills/audit/SKILL.md` — update Steps 2c, 2d, add Step 0.5
- **No Rails changes** — existing GraphQL schema supports all needed queries

## HIPAA notes

- Run IDs are not PHI — safe to log and display
- Execution outputs may contain PHI (patient names in extracted text) — same chmod 0600 / error truncation rules as download_project.rb apply if writing to disk
- This CLI does NOT write files to disk by default — it outputs JSON to stdout for the agent to consume in-memory
