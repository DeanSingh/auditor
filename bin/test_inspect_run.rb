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
  # Test 4: Drill-down with iteration range
  # -------------------------------------------------------------------
  def test_drill_down_with_iteration_range
    mount_response({
      'data' => {
        'run' => {
          'executions' => [
            { 'iteration' => 10, 'status' => 'SUCCEEDED',
              'output' => 'a', 'result' => nil, 'prompt' => nil,
              'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil },
            { 'iteration' => 11, 'status' => 'SUCCEEDED',
              'output' => 'b', 'result' => nil, 'prompt' => nil,
              'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil }
          ]
        }
      }
    })

    out, status = run_script('200', '--step', 'Extract Info', '--iterations', '10-11', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal 2, result['executions'].length
    assert_equal 10, result['executions'][0]['iteration']
    assert_equal 11, result['executions'][1]['iteration']
  end

  # -------------------------------------------------------------------
  # Test 5: Rejects combining --iteration and --iterations
  # -------------------------------------------------------------------
  def test_rejects_iteration_and_iterations_together
    out, status = run_script('200', '--step', 'Extract Info', '--iteration', '5', '--iterations', '10-20', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'mutually exclusive'
  end

  # -------------------------------------------------------------------
  # Test 6: Rejects invalid --iterations format
  # -------------------------------------------------------------------
  def test_rejects_invalid_iterations_format
    out, status = run_script('200', '--step', 'Extract Info', '--iterations', 'abc', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'format N-M'
  end

  # -------------------------------------------------------------------
  # Test 7: Exits with error for invalid input
  # -------------------------------------------------------------------
  def test_exits_with_error_for_invalid_input
    out, status = run_script('not-a-number', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'Could not parse run ID'
  end

  # -------------------------------------------------------------------
  # Test 8: Exits with error when no arguments given
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
