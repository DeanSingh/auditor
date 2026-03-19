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

  def test_summary_mode
    mount_run(
      id: '200', status: 'SUCCEEDED',
      started: '2026-03-01T10:00:00Z', finished: '2026-03-01T11:00:00Z',
      workflow: {
        'name' => 'Record Review',
        'steps' => [
          { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'PROMPT', 'priority' => 1,
            'action' => { '__typename' => 'Action__Prompt',
                          'messages' => [{ 'role' => 'USER', 'template' => 'Extract the date' }] } },
          { 'id' => '2', 'name' => 'File Loop', 'kind' => 'ITERATOR', 'priority' => 2,
            'action' => { '__typename' => 'Action__Iterator' } }
        ]
      },
      executions: [
        { 'id' => '1', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
        { 'id' => '2', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Extract Info' } },
        { 'id' => '3', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'File Loop' } }
      ]
    )

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

  def test_drill_down_mode
    mount_run(
      executions: [
        { 'iteration' => 5, 'status' => 'SUCCEEDED',
          'output' => 'Date: 2024-12-11', 'result' => { 'date' => '2024-12-11' },
          'prompt' => 'Extract date from page', 'step' => { 'name' => 'Extract Info' },
          'started' => '2026-03-01T10:00:00Z', 'finished' => '2026-03-01T10:00:05Z' }
      ]
    )

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

  def test_parses_run_id_from_url
    mount_run(id: '8564')

    out, status = run_script('https://workflow.ing/dashboard/runs/8564', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '8564', result.dig('run', 'id')
  end

  def test_drill_down_with_iteration_range
    mount_run(
      executions: [
        { 'iteration' => 10, 'status' => 'SUCCEEDED',
          'output' => 'a', 'result' => nil, 'prompt' => nil,
          'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil },
        { 'iteration' => 11, 'status' => 'SUCCEEDED',
          'output' => 'b', 'result' => nil, 'prompt' => nil,
          'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil }
      ]
    )

    out, status = run_script('200', '--step', 'Extract Info', '--iterations', '10-11', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal 2, result['executions'].length
    assert_equal 10, result['executions'][0]['iteration']
    assert_equal 11, result['executions'][1]['iteration']
  end

  def test_rejects_iteration_and_iterations_together
    out, status = run_script('200', '--step', 'Extract Info', '--iteration', '5', '--iterations', '10-20', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'mutually exclusive'
  end

  def test_rejects_invalid_iterations_format
    out, status = run_script('200', '--step', 'Extract Info', '--iterations', 'abc', '--base-url', @base_url)
    refute status.success?
    assert_includes out, '--iterations must be a range'
  end

  def test_exits_with_error_for_invalid_input
    out, status = run_script('not-a-number', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'Could not parse run ID'
  end

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

  # Build a run response with sensible defaults.
  # The mock server returns the same response for all GraphQL queries, so the
  # response must satisfy both resolve_step_name! (needs workflow.steps) and
  # the actual mode query (summary/drill-down). This helper provides minimal
  # defaults so each test only specifies what it cares about.
  def mount_run(id: '200', status: 'SUCCEEDED', started: nil, finished: nil,
                workflow: nil, executions: [])
    # Infer a minimal workflow from the executions if not provided.
    # resolve_step_name! needs workflow.steps to validate the --step flag.
    workflow ||= default_workflow(executions)

    mount_response({
      'data' => {
        'run' => {
          'id' => id, 'status' => status,
          'started' => started, 'finished' => finished,
          'stats' => default_stats(executions),
          'workflow' => workflow,
          'executions' => executions
        }
      }
    })
  end

  # Infer step names from executions and build a minimal workflow hash.
  def default_workflow(executions)
    step_names = executions.filter_map { |e| e.dig('step', 'name') }.uniq
    steps = step_names.each_with_index.map do |name, i|
      { 'id' => (i + 1).to_s, 'name' => name, 'kind' => 'PROMPT', 'priority' => i + 1,
        'action' => { '__typename' => 'Action__Prompt', 'messages' => [] } }
    end
    { 'name' => 'Record Review', 'steps' => steps }
  end

  def default_stats(executions)
    succeeded = executions.count { |e| e['status'] == 'SUCCEEDED' }
    failed = executions.count { |e| e['status'] == 'FAILED' }
    step_count = executions.filter_map { |e| e.dig('step', 'name') }.uniq.size
    {
      'executionCount' => executions.size,
      'stepCount' => step_count,
      'failedExecutionCount' => failed,
      'succeededExecutionCount' => succeeded
    }
  end

  # Returns a single-org response for the organizations query so
  # auto_resolve_org_id succeeds, then returns the run data for all other queries.
  def mount_response(response_hash)
    org_response = {
      'data' => {
        'organizations' => [{ 'id' => 'org_1', 'name' => 'Test Org', 'current' => true }]
      }
    }

    @server.mount_proc('/graphql') do |req, res|
      body = JSON.parse(req.body)
      result = body['query'].include?('organizations') ? org_response : response_hash

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(result)
    end
  end
end
