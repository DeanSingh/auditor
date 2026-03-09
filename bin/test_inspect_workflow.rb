#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'webrick'
require 'json'
require 'open3'

# Tests for bin/inspect_workflow.rb CLI.
# Spins up a local WEBrick server that fakes the GraphQL API,
# then runs the script as a subprocess and checks its JSON output.
class TestInspectWorkflow < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"
    @server_thread = Thread.new { @server.start }
    @script = File.expand_path('../inspect_workflow.rb', __FILE__)
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  # -------------------------------------------------------------------
  # Test 1: List mode returns workflows
  # -------------------------------------------------------------------
  def test_list_mode
    mount_response({
      'data' => {
        'workflows' => [
          { 'id' => '1', 'name' => 'Record Review' },
          { 'id' => '2', 'name' => 'Billing Weekly' }
        ]
      }
    })

    out, status = run_script('--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal 2, result['workflows'].length
    assert_equal 'Record Review', result['workflows'][0]['name']
    assert_equal 'Billing Weekly', result['workflows'][1]['name']
  end

  # -------------------------------------------------------------------
  # Test 2: Detail mode returns workflow with steps
  # -------------------------------------------------------------------
  def test_detail_mode
    mount_response({
      'data' => {
        'workflow' => {
          'id' => '42',
          'name' => 'Record Review',
          'steps' => [
            { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'ITERATOR', 'priority' => 0,
              'action' => { 'kind' => 'pages', 'overKey' => 'pages' } },
            { 'id' => '2', 'name' => 'Extract Output', 'kind' => 'PROMPT', 'priority' => 1,
              'action' => { 'model' => 'claude-sonnet-4-20250514', 'temperature' => 0.0, 'format' => 'TEXT',
                            'messages' => [{ 'role' => 'USER', 'template' => 'Extract from {{page}}' }] } },
            { 'id' => '3', 'name' => 'Build Letters', 'kind' => 'CODE', 'priority' => 3,
              'action' => { 'template' => 'DocumentSplitService.call(input)' } }
          ]
        }
      }
    })

    out, status = run_script('42', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '42', result.dig('workflow', 'id')
    assert_equal 'Record Review', result.dig('workflow', 'name')

    steps = result['steps']
    assert_equal 3, steps.length

    # Steps should be sorted by priority
    assert_equal 'Extract Info', steps[0]['name']
    assert_equal 0, steps[0]['priority']
    assert_equal 'Extract Output', steps[1]['name']
    assert_equal 1, steps[1]['priority']
    assert_equal 'Build Letters', steps[2]['name']
    assert_equal 3, steps[2]['priority']

    # Action details should be flattened by kind
    assert_equal 'pages', steps[0].dig('iterator', 'overKey')
    assert_equal 'claude-sonnet-4-20250514', steps[1]['model']
    assert_includes steps[1], 'prompt_template'
    assert_equal 'DocumentSplitService.call(input)', steps[2]['code']
  end

  # -------------------------------------------------------------------
  # Test 3: List mode with --query filter
  # -------------------------------------------------------------------
  def test_list_mode_with_query
    mount_response({
      'data' => {
        'workflows' => [
          { 'id' => '1', 'name' => 'Record Review' }
        ]
      }
    })

    out, status = run_script('--query', 'Record', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal 1, result['workflows'].length
    assert_equal 'Record Review', result['workflows'][0]['name']
  end

  # -------------------------------------------------------------------
  # Test 4: Parses workflow ID from URL
  # -------------------------------------------------------------------
  def test_parses_workflow_id_from_url
    mount_response({
      'data' => {
        'workflow' => {
          'id' => '42',
          'name' => 'Record Review',
          'steps' => []
        }
      }
    })

    out, status = run_script('https://workflow.ing/dashboard/workflows/42', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '42', result.dig('workflow', 'id')
  end

  # -------------------------------------------------------------------
  # Test 5: --help flag exits successfully
  # -------------------------------------------------------------------
  def test_help_flag
    out, status = run_script('--help')
    assert status.success?, "Script failed: #{out}"
    assert_includes out, 'Inspect workflows'
    assert_includes out, '--query'
    assert_includes out, '--org'
    assert_includes out, '--base-url'
  end

  # -------------------------------------------------------------------
  # Test 6: Exits with error for invalid workflow ID
  # -------------------------------------------------------------------
  def test_exits_with_error_for_invalid_input
    out, status = run_script('not-a-number', '--base-url', @base_url)
    refute status.success?
    assert_includes out, 'Could not parse workflow ID'
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
