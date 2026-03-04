# Inspect Run CLI — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `bin/inspect_run.rb` CLI that queries workflow run data via GraphQL so the auditor agent can inspect step executions without opening a browser.

**Architecture:** Two-tier command — summary mode returns workflow structure + per-step execution counts, drill-down mode returns full execution data for a specific step + iteration range. Reuses existing `WorkflowClient` and `AuditorConfig`. No Rails changes needed.

**Tech Stack:** Ruby 3.0+, minitest, WEBrick (test server), GraphQL queries against existing Workflow Labs API

**Design doc:** `docs/plans/2026-03-03-inspect-run-cli-design.md`

---

### Task 1: Add GraphQL queries to WorkflowClient

**Files:**
- Modify: `lib/workflow_client.rb`
- Test: `bin/test_workflow_client.rb`

**Step 1: Write the failing test for `fetch_run_summary`**

Add to `bin/test_workflow_client.rb`, after the existing `test_graphql_error_short_message_not_truncated` test:

```ruby
# -------------------------------------------------------------------
# Test 13: Fetches run summary data
# -------------------------------------------------------------------
def test_fetches_run_summary
  run_data = {
    'data' => {
      'run' => {
        'id' => '100',
        'status' => 'SUCCEEDED',
        'started' => '2026-03-01T10:00:00Z',
        'finished' => '2026-03-01T11:00:00Z',
        'stats' => {
          'executionCount' => 50,
          'stepCount' => 5,
          'failedExecutionCount' => 0,
          'succeededExecutionCount' => 50
        },
        'workflow' => {
          'name' => 'Record Review',
          'steps' => [
            { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'PROMPT', 'priority' => 1,
              'action' => { '__typename' => 'Action__Prompt', 'messages' => [{ 'role' => 'USER', 'template' => 'Extract date from {{page}}' }] } },
            { 'id' => '2', 'name' => 'File Loop', 'kind' => 'ITERATOR', 'priority' => 2,
              'action' => { '__typename' => 'Action__Iterator' } }
          ]
        },
        'executions' => [
          { 'id' => '1', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
          { 'id' => '2', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
          { 'id' => '3', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'File Loop' } }
        ]
      }
    }
  }

  mount_graphql_response(run_data)

  client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
  result = client.fetch_run_summary('100')

  assert_equal '100', result['id']
  assert_equal 'SUCCEEDED', result['status']
  assert_equal 'Record Review', result['workflow']['name']
  assert_equal 2, result['workflow']['steps'].length
  assert_equal 3, result['executions'].length
end
```

**Step 2: Run test to verify it fails**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb --name test_fetches_run_summary`
Expected: FAIL with "undefined method `fetch_run_summary'"

**Step 3: Write the implementation**

Add two new query constants and two new public methods to `lib/workflow_client.rb`. Add these constants after the existing `GRAPHQL_QUERY`:

```ruby
RUN_SUMMARY_QUERY = <<~GRAPHQL
  query InspectRun($id: ID!) {
    run(id: $id) {
      id
      status
      started
      finished
      stats {
        executionCount
        stepCount
        failedExecutionCount
        succeededExecutionCount
      }
      workflow {
        name
        steps {
          id
          name
          kind
          priority
          action {
            ... on Action__Prompt {
              messages { role template }
            }
          }
        }
      }
      executions {
        id
        status
        step { name }
      }
    }
  }
GRAPHQL

RUN_EXECUTIONS_QUERY = <<~GRAPHQL
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
GRAPHQL
```

Add these public methods after the existing `fetch_project` method:

```ruby
# Fetches a run summary (workflow structure + lightweight execution list).
# Returns the run hash with workflow, steps, stats, and execution ids/statuses.
def fetch_run_summary(run_id)
  uri = URI("#{@base_url}/graphql")
  body = JSON.generate(query: RUN_SUMMARY_QUERY, variables: { id: run_id })
  response = post_json(uri, body)
  data = parse_response(response)
  data['run']
end

# Fetches execution details for a specific step and iteration range.
# Returns the run hash with filtered executions including full output/result.
def fetch_run_executions(run_id, step_name:, iteration: nil, iteration_min: nil, iteration_max: nil)
  uri = URI("#{@base_url}/graphql")

  filter = { stepName: step_name }
  filter[:iteration] = iteration if iteration
  filter[:iterationMin] = iteration_min if iteration_min
  filter[:iterationMax] = iteration_max if iteration_max

  body = JSON.generate(
    query: RUN_EXECUTIONS_QUERY,
    variables: { id: run_id, filter: filter }
  )

  response = post_json(uri, body)
  data = parse_response(response)
  data['run']
end
```

**Step 4: Run test to verify it passes**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb --name test_fetches_run_summary`
Expected: PASS

**Step 5: Commit**

```bash
cd ~/git/auditor
git add lib/workflow_client.rb bin/test_workflow_client.rb
git commit -m "Add fetch_run_summary and fetch_run_executions to WorkflowClient"
```

---

### Task 2: Add test for `fetch_run_executions`

**Files:**
- Test: `bin/test_workflow_client.rb`

**Step 1: Write the test**

Add after `test_fetches_run_summary`:

```ruby
# -------------------------------------------------------------------
# Test 14: Fetches filtered run executions with correct filter variables
# -------------------------------------------------------------------
def test_fetches_run_executions_with_filter
  run_data = {
    'data' => {
      'run' => {
        'executions' => [
          { 'iteration' => 5, 'status' => 'SUCCEEDED', 'output' => 'Date: 2024-12-11',
            'result' => { 'date' => '2024-12-11' }, 'prompt' => 'Extract date...',
            'step' => { 'name' => 'Extract Info' }, 'started' => '2026-03-01T10:00:00Z',
            'finished' => '2026-03-01T10:00:05Z' }
        ]
      }
    }
  }

  mount_graphql_response(run_data)

  client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
  result = client.fetch_run_executions('100', step_name: 'Extract Info', iteration: 5)

  assert_equal 1, result['executions'].length
  exec = result['executions'].first
  assert_equal 5, exec['iteration']
  assert_equal 'Date: 2024-12-11', exec['output']

  # Verify the filter was sent in the request body
  parsed = JSON.parse(@received_body)
  assert_equal 'Extract Info', parsed['variables']['filter']['stepName']
  assert_equal 5, parsed['variables']['filter']['iteration']
end

# -------------------------------------------------------------------
# Test 15: Fetches run executions with iteration range
# -------------------------------------------------------------------
def test_fetches_run_executions_with_range
  run_data = {
    'data' => {
      'run' => {
        'executions' => [
          { 'iteration' => 10, 'status' => 'SUCCEEDED', 'output' => 'a', 'result' => nil,
            'prompt' => nil, 'step' => { 'name' => 'Extract Info' },
            'started' => nil, 'finished' => nil },
          { 'iteration' => 11, 'status' => 'SUCCEEDED', 'output' => 'b', 'result' => nil,
            'prompt' => nil, 'step' => { 'name' => 'Extract Info' },
            'started' => nil, 'finished' => nil }
        ]
      }
    }
  }

  mount_graphql_response(run_data)

  client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
  result = client.fetch_run_executions('100', step_name: 'Extract Info', iteration_min: 10, iteration_max: 11)

  assert_equal 2, result['executions'].length

  parsed = JSON.parse(@received_body)
  filter = parsed['variables']['filter']
  assert_equal 10, filter['iterationMin']
  assert_equal 11, filter['iterationMax']
  assert_nil filter['iteration']
end
```

**Step 2: Run tests to verify they pass**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb --name /test_fetches_run_executions/`
Expected: 2 tests PASS

**Step 3: Commit**

```bash
cd ~/git/auditor
git add bin/test_workflow_client.rb
git commit -m "Add tests for fetch_run_executions with single iteration and range"
```

---

### Task 3: Create `bin/inspect_run.rb` — argument parsing and summary mode

**Files:**
- Create: `bin/inspect_run.rb`

**Step 1: Write the script**

Create `bin/inspect_run.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/config'
require_relative '../lib/workflow_client'

# Inspects a workflow run via the GraphQL API.
#
# Two modes:
#   Summary:    bin/inspect_run.rb <run_id>
#   Drill-down: bin/inspect_run.rb <run_id> --step "Extract Info" --iteration 123
#
# Outputs JSON to stdout for consumption by the auditor agent.
#
# HIPAA notes:
#   - Execution outputs may contain PHI — this tool outputs to stdout only (no files written)
#   - Error messages are truncated to avoid leaking PHI
class RunInspector
  MAX_ERROR_LENGTH = 100

  def initialize(run_id, step_name: nil, iteration: nil, iterations: nil, base_url: nil, org_name: nil)
    @run_id = run_id
    @step_name = step_name
    @iteration = iteration
    @iterations = iterations

    config = AuditorConfig.new
    base = base_url || config.base_url

    org_id = resolve_org(base, config.token!, org_name) if org_name

    @client = WorkflowClient.new(
      base_url: base,
      token: config.token!,
      org_id: org_id
    )
  end

  def run
    if @step_name
      drill_down
    else
      summary
    end
  end

  private

  def summary
    data = @client.fetch_run_summary(@run_id)

    if data.nil?
      warn "Error: Run #{@run_id} not found"
      exit 1
    end

    # Group executions by step name for per-step counts
    exec_by_step = Hash.new { |h, k| h[k] = { succeeded: 0, failed: 0, other: 0 } }
    (data['executions'] || []).each do |e|
      step_name = e.dig('step', 'name') || 'unknown'
      case e['status']&.downcase
      when 'succeeded' then exec_by_step[step_name][:succeeded] += 1
      when 'failed' then exec_by_step[step_name][:failed] += 1
      else exec_by_step[step_name][:other] += 1
      end
    end

    # Build step list with execution counts and prompt templates
    steps = (data.dig('workflow', 'steps') || []).sort_by { |s| s['priority'] || 0 }.map do |step|
      counts = exec_by_step[step['name']]
      entry = {
        'name' => step['name'],
        'kind' => step['kind'],
        'execution_count' => counts[:succeeded] + counts[:failed] + counts[:other],
        'succeeded' => counts[:succeeded],
        'failed' => counts[:failed]
      }

      # Include prompt template for Prompt-type steps
      messages = step.dig('action', 'messages')
      if messages && !messages.empty?
        entry['prompt_template'] = messages.map { |m| "#{m['role']}: #{m['template']}" }.join("\n\n")
      end

      entry
    end

    output = {
      'run' => {
        'id' => data['id'],
        'status' => data['status'],
        'started' => data['started'],
        'finished' => data['finished']
      },
      'workflow' => {
        'name' => data.dig('workflow', 'name'),
        'steps' => steps
      },
      'stats' => data['stats']
    }

    puts JSON.pretty_generate(output)
  end

  def drill_down
    iter = @iteration
    iter_min = nil
    iter_max = nil

    if @iterations
      parts = @iterations.split('-', 2)
      iter_min = parts[0].to_i
      iter_max = parts[1].to_i
    end

    data = @client.fetch_run_executions(
      @run_id,
      step_name: @step_name,
      iteration: iter,
      iteration_min: iter_min,
      iteration_max: iter_max
    )

    if data.nil?
      warn "Error: Run #{@run_id} not found"
      exit 1
    end

    executions = (data['executions'] || []).map do |e|
      {
        'iteration' => e['iteration'],
        'status' => e['status'],
        'output' => e['output'],
        'result' => e['result'],
        'prompt' => e['prompt'],
        'started' => e['started'],
        'finished' => e['finished']
      }
    end

    output = {
      'step' => @step_name,
      'executions' => executions
    }

    puts JSON.pretty_generate(output)
  end

  def resolve_org(base_url, token, name)
    client = WorkflowClient.new(base_url: base_url, token: token, org_id: nil)
    orgs = client.fetch_organizations
    match = orgs.find { |o| o['name'].downcase == name.downcase }

    if match.nil?
      available = orgs.map { |o| o['name'] }.join(', ')
      warn "Error: Organization \"#{name}\" not found"
      warn "Available: #{available}"
      exit 1
    end

    match['id']
  end
end

# Main execution
if __FILE__ == $0
  step_name = nil
  iteration = nil
  iterations = nil
  base_url = nil
  org_name = nil

  parser = OptionParser.new do |opts|
    opts.banner = "Inspect a workflow run via the GraphQL API\n\n"
    opts.banner += "Usage: #{$0} <run_id> [options]\n"
    opts.banner += "       #{$0} <run_url> [options]"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('--step NAME', 'Step name to drill into (e.g., "Extract Info")') do |name|
      step_name = name
    end

    opts.on('--iteration N', Integer, 'Single iteration to fetch (0-indexed)') do |n|
      iteration = n
    end

    opts.on('--iterations RANGE', 'Iteration range to fetch (e.g., "99-123")') do |range|
      iterations = range
    end

    opts.on('--org NAME', 'Organization name') do |name|
      org_name = name
    end

    opts.on('--base-url URL', 'Override Workflow Labs base URL') do |url|
      base_url = url
    end

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      puts
      puts 'Modes:'
      puts '  Summary (no --step):     Shows workflow structure and per-step execution counts'
      puts '  Drill-down (with --step): Shows full execution data for a step + iteration'
      puts
      puts 'Examples:'
      puts "  #{$0} 8564                                     # Summary"
      puts "  #{$0} https://workflow.ing/dashboard/runs/8564  # Summary (URL)"
      puts "  #{$0} 8564 --step \"Extract Info\" --iteration 123"
      puts "  #{$0} 8564 --step \"Extract Info\" --iterations 99-123"
      puts "  #{$0} 8564 --org \"Acme Medical\""
      exit 0
    end
  end

  parser.parse!

  if ARGV.empty?
    warn 'Error: run_id is required'
    warn
    warn parser.banner
    warn
    warn 'Run with --help for usage information'
    exit 1
  end

  arg = ARGV.first
  run_id = if arg =~ %r{/runs/(\d+)}
             $1
           elsif arg =~ /\A\d+\z/
             arg
           else
             warn "Error: Could not parse run ID from: #{arg}"
             warn 'Expected a number (e.g., 8564) or a URL (e.g., https://workflow.ing/dashboard/runs/8564)'
             exit 1
           end

  begin
    inspector = RunInspector.new(
      run_id,
      step_name: step_name,
      iteration: iteration,
      iterations: iterations,
      base_url: base_url,
      org_name: org_name
    )
    inspector.run
  rescue AuditorConfig::MissingConfigError => e
    warn e.message
    exit 1
  rescue WorkflowClient::GraphQLError => e
    warn "Error: GraphQL query failed — #{e.message}"
    exit 1
  rescue WorkflowClient::HTTPError => e
    warn "Error: HTTP request failed — #{e.message}"
    exit 1
  rescue WorkflowClient::InsecureConnectionError => e
    warn "Error: #{e.message}"
    exit 1
  rescue StandardError => e
    msg = "#{e.class}: #{e.message}"
    msg = "#{msg[0...100]}..." if msg.length > 100
    warn "Unexpected error: #{msg}"
    exit 1
  end
end
```

**Step 2: Make it executable**

Run: `chmod +x ~/git/auditor/bin/inspect_run.rb`

**Step 3: Commit**

```bash
cd ~/git/auditor
git add bin/inspect_run.rb
git commit -m "Add inspect_run.rb CLI with summary and drill-down modes"
```

---

### Task 4: Add tests for `bin/inspect_run.rb`

**Files:**
- Create: `bin/test_inspect_run.rb`

**Step 1: Write the test file**

Create `bin/test_inspect_run.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'webrick'
require 'json'
require 'open3'

# Tests for bin/inspect_run.rb CLI.
# Spins up a local WEBrick server that fakes the GraphQL API,
# then runs the script as a subprocess and checks its JSON output.
class TestInspectRun < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"
    @server_thread = Thread.new { @server.start }
    @script = File.expand_path('../inspect_run.rb', __FILE__)
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  # -------------------------------------------------------------------
  # Test 1: Summary mode returns workflow structure with per-step counts
  # -------------------------------------------------------------------
  def test_summary_mode
    mount_response({
      'data' => {
        'run' => {
          'id' => '200', 'status' => 'SUCCEEDED',
          'started' => '2026-03-01T10:00:00Z', 'finished' => '2026-03-01T11:00:00Z',
          'stats' => { 'executionCount' => 3, 'stepCount' => 2, 'failedExecutionCount' => 0, 'succeededExecutionCount' => 3 },
          'workflow' => {
            'name' => 'Record Review',
            'steps' => [
              { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'PROMPT', 'priority' => 1,
                'action' => { '__typename' => 'Action__Prompt', 'messages' => [{ 'role' => 'USER', 'template' => 'Extract the date' }] } },
              { 'id' => '2', 'name' => 'File Loop', 'kind' => 'ITERATOR', 'priority' => 2,
                'action' => { '__typename' => 'Action__Iterator' } }
            ]
          },
          'executions' => [
            { 'id' => '1', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
            { 'id' => '2', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
            { 'id' => '3', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'File Loop' } }
          ]
        }
      }
    })

    out, status = run_script('200', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '200', result.dig('run', 'id')
    assert_equal 'Record Review', result.dig('workflow', 'name')

    steps = result.dig('workflow', 'steps')
    assert_equal 2, steps.length

    extract = steps.find { |s| s['name'] == 'Extract Info' }
    assert_equal 2, extract['execution_count']
    assert_equal 2, extract['succeeded']
    assert_includes extract['prompt_template'], 'Extract the date'

    file_loop = steps.find { |s| s['name'] == 'File Loop' }
    assert_equal 1, file_loop['execution_count']
    assert_nil file_loop['prompt_template']
  end

  # -------------------------------------------------------------------
  # Test 2: Drill-down mode returns execution details
  # -------------------------------------------------------------------
  def test_drill_down_mode
    mount_response({
      'data' => {
        'run' => {
          'executions' => [
            { 'iteration' => 5, 'status' => 'SUCCEEDED',
              'output' => 'Date: 2024-12-11', 'result' => { 'date' => '2024-12-11' },
              'prompt' => 'Extract date from page', 'step' => { 'name' => 'Extract Info' },
              'started' => '2026-03-01T10:00:00Z', 'finished' => '2026-03-01T10:00:05Z' }
          ]
        }
      }
    })

    out, status = run_script('200', '--step', 'Extract Info', '--iteration', '5', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal 'Extract Info', result['step']
    assert_equal 1, result['executions'].length

    exec = result['executions'].first
    assert_equal 5, exec['iteration']
    assert_equal 'Date: 2024-12-11', exec['output']
    assert_equal({ 'date' => '2024-12-11' }, exec['result'])
  end

  # -------------------------------------------------------------------
  # Test 3: Parses run ID from URL
  # -------------------------------------------------------------------
  def test_parses_run_id_from_url
    mount_response({
      'data' => {
        'run' => {
          'id' => '8564', 'status' => 'SUCCEEDED', 'started' => nil, 'finished' => nil,
          'stats' => { 'executionCount' => 0, 'stepCount' => 0, 'failedExecutionCount' => 0, 'succeededExecutionCount' => 0 },
          'workflow' => { 'name' => 'Test', 'steps' => [] },
          'executions' => []
        }
      }
    })

    out, status = run_script('https://workflow.ing/dashboard/runs/8564', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '8564', result.dig('run', 'id')
  end

  # -------------------------------------------------------------------
  # Test 4: Exits with error for invalid input
  # -------------------------------------------------------------------
  def test_exits_with_error_for_invalid_input
    out, status = run_script('not-a-number', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'Could not parse run ID'
  end

  # -------------------------------------------------------------------
  # Test 5: Exits with error when no arguments given
  # -------------------------------------------------------------------
  def test_exits_with_error_when_no_args
    out, status = run_script('--base-url', @base_url)
    refute status.success?
    assert_includes out, 'run_id is required'
  end

  private

  def run_script(*args)
    env = { 'WORKFLOW_API_TOKEN' => 'test_token' }
    stdout_and_stderr, status = Open3.capture2e(env, 'ruby', @script, *args)
    [stdout_and_stderr, status]
  end

  def mount_response(response_hash)
    @server.mount_proc('/graphql') do |_req, res|
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(response_hash)
    end
  end
end
```

**Step 2: Run the tests**

Run: `cd ~/git/auditor && ruby bin/test_inspect_run.rb`
Expected: 5 tests, 5 passed

**Step 3: Commit**

```bash
cd ~/git/auditor
git add bin/test_inspect_run.rb
git commit -m "Add tests for inspect_run.rb CLI"
```

---

### Task 5: Update SKILL.md to use inspect CLI

**Files:**
- Modify: `~/.claude/skills/audit/SKILL.md`

**Step 1: Add Step 0.5 after Step 0**

After the existing Step 0 section (line 65 — "If `$ARGUMENTS` is NOT a number or URL..."), add:

```markdown
## Step 0.5: Run Inspection (after download)

If Step 0 downloaded a project, inspect the latest run to get workflow structure and prompt templates.

1. **Get the run ID** from the download output (shown as "run outputs from run <id>")

2. **Run the summary inspection:**
   ```bash
   cd ~/git/auditor && ruby bin/inspect_run.rb <run_id>
   ```
   Or with a URL:
   ```bash
   cd ~/git/auditor && ruby bin/inspect_run.rb https://workflow.ing/dashboard/runs/<run_id>
   ```

3. **Read the JSON output** to understand:
   - Workflow name and step names (e.g., "Extract Info", "Medical Summary", "Build Letters")
   - Per-step execution counts and pass/fail rates
   - Prompt templates for Prompt-type steps (these are the instructions the AI followed)

4. **Save the run ID** for use in Steps 2c and 2d drill-downs.
```

**Step 2: Update Step 2c to use CLI instead of browser**

Replace the "Using the Workflow.ing Runs Page" subsection in Step 2c (lines 149-163) with:

```markdown
### Using the Inspect CLI

For any entry with a date issue, drill into the Extract Info step for that page's iteration:

1. **Pages are 0-indexed in iterations**: page 1 = iteration 0, page 100 = iteration 99, page 124 = iteration 123
2. Run the drill-down:
   ```bash
   cd ~/git/auditor && ruby bin/inspect_run.rb <run_id> --step "Extract Info" --iteration <N>
   ```
   For multiple pages at once:
   ```bash
   cd ~/git/auditor && ruby bin/inspect_run.rb <run_id> --step "Extract Info" --iterations 99-123
   ```
3. The JSON output contains for each iteration:
   - **output**: The extracted date, date type, header, footer, and the AI's reasoning (Thoughts)
   - **result**: Structured JSON with the extracted fields
   - **prompt**: The rendered prompt that was sent to the LLM
4. Check the `output` field for the AI's "Thoughts" section, which explains WHY it chose or rejected each date
```

**Step 3: Update Step 2d to use CLI instead of browser**

Replace the "1. Check the Letters Loop" subsection in Step 2d (lines 180-188) with:

```markdown
### 1. Check the Letters Loop (AI's summary thinking)

Drill into the Medical Summary step for the letter's iteration:

```bash
cd ~/git/auditor && ruby bin/inspect_run.rb <run_id> --step "Medical Summary" --iteration <N>
```

The `output` field shows the AI's thinking, including:
- What **sub-category** the AI identified
- Which **template** it chose to follow
- What it decided to include/exclude and why
```

Replace the "2. Check the Medical Summary step instructions" subsection (lines 190-196) with:

```markdown
### 2. Check the Medical Summary step instructions

The prompt template for Medical Summary is included in the Step 0.5 summary output (under `workflow.steps` where `name` = "Medical Summary" and `prompt_template` is present).

Read the instructions for the **specific sub-category** the AI chose. Each sub-category has its own template defining exactly what content to include.
```

**Step 4: Commit**

```bash
git add ~/.claude/skills/audit/SKILL.md
git commit -m "Update SKILL.md to use inspect_run.rb CLI instead of browser"
```

---

### Task 6: Run all tests and verify

**Step 1: Run all workflow client tests**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb`
Expected: All tests pass (including existing tests 1-12 plus new tests 13-15)

**Step 2: Run all inspect run tests**

Run: `cd ~/git/auditor && ruby bin/test_inspect_run.rb`
Expected: All 5 tests pass

**Step 3: Run existing test suite to ensure nothing broke**

Run: `cd ~/git/auditor && ruby bin/test_config.rb`
Expected: All tests pass

**Step 4: Manual smoke test against production**

Run: `cd ~/git/auditor && ruby bin/inspect_run.rb 8558`
Expected: JSON output with run summary, workflow steps, and execution counts

Run: `cd ~/git/auditor && ruby bin/inspect_run.rb 8558 --step "Extract Info" --iteration 0`
Expected: JSON output with one execution containing output, result, and prompt fields
