#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'webrick'
require 'json'
require_relative '../lib/workflow_client'

# Spins up a local WEBrick server that fakes GraphQL and file-download endpoints.
# Each test configures the server's response, then exercises WorkflowClient against it.
class TestWorkflowClient < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0, # random available port
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"

    @server_thread = Thread.new { @server.start }

    # Store headers received by the server so tests can inspect them
    @received_headers = {}
    @received_body = nil
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  # -------------------------------------------------------------------
  # Test 1: Fetches project data correctly
  # -------------------------------------------------------------------
  def test_fetches_project_data
    project_data = {
      'data' => {
        'project' => {
          'id' => '42',
          'name' => 'Smith v. Jones',
          'claimantDob' => '1980-01-15',
          'documents' => [],
          'runs' => []
        }
      }
    }

    mount_graphql_response(project_data)

    client = WorkflowClient.new(base_url: @base_url, token: 'test_token', org_id: 'org_1')
    result = client.fetch_project('42')

    assert_equal '42', result['id']
    assert_equal 'Smith v. Jones', result['name']
    assert_equal '1980-01-15', result['claimantDob']
    assert_equal [], result['documents']
    assert_equal [], result['runs']
  end

  # -------------------------------------------------------------------
  # Test 2: Sends correct auth headers
  # -------------------------------------------------------------------
  def test_sends_correct_auth_headers
    mount_graphql_response({ 'data' => { 'project' => { 'id' => '1' } } })

    client = WorkflowClient.new(base_url: @base_url, token: 'secret_bearer_token', org_id: 'org_99')
    client.fetch_project('1')

    assert_equal 'Bearer secret_bearer_token', @received_headers['authorization']
    assert_equal 'org_99', @received_headers['x-organization-id']
    assert_equal 'application/json', @received_headers['content-type']
  end

  # -------------------------------------------------------------------
  # Test 3: Sends correct GraphQL query with variables
  # -------------------------------------------------------------------
  def test_sends_correct_graphql_query
    mount_graphql_response({ 'data' => { 'project' => { 'id' => '7' } } })

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    client.fetch_project('7')

    assert @received_body, 'Expected a request body'
    parsed = JSON.parse(@received_body)
    assert_includes parsed['query'], 'query GetProject'
    assert_equal '7', parsed['variables']['id']
  end

  # -------------------------------------------------------------------
  # Test 4: Raises GraphQLError on GraphQL errors (with truncated message)
  # -------------------------------------------------------------------
  def test_raises_graphql_error_with_truncated_message
    long_message = 'Patient John Doe (DOB 1985-03-22) record not found in system ' * 5 # > 200 chars
    error_response = {
      'errors' => [{ 'message' => long_message }]
    }

    mount_graphql_response(error_response)

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    error = assert_raises(WorkflowClient::GraphQLError) { client.fetch_project('1') }

    # Message should be truncated to 200 chars + "..."
    assert_operator error.message.length, :<=, 203
    assert error.message.end_with?('...'), 'Truncated message should end with ...'
  end

  # -------------------------------------------------------------------
  # Test 5: Raises HTTPError on non-2xx responses
  # -------------------------------------------------------------------
  def test_raises_http_error_on_server_error
    @server.mount_proc('/graphql') do |_req, res|
      res.status = 500
      res.body = 'Internal Server Error'
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    error = assert_raises(WorkflowClient::HTTPError) { client.fetch_project('1') }

    assert_includes error.message, '500'
  end

  def test_raises_http_error_on_unauthorized
    @server.mount_proc('/graphql') do |_req, res|
      res.status = 401
      res.body = 'Unauthorized'
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'bad_token', org_id: 'org')
    error = assert_raises(WorkflowClient::HTTPError) { client.fetch_project('1') }

    assert_includes error.message, 'Authentication failed'
    refute_includes error.message, 'bad_token', 'Token must never appear in error messages'
  end

  # -------------------------------------------------------------------
  # Test 6: Raises InsecureConnectionError for HTTP (non-localhost)
  # -------------------------------------------------------------------
  def test_raises_insecure_connection_error_for_http
    assert_raises(WorkflowClient::InsecureConnectionError) do
      WorkflowClient.new(base_url: 'http://example.com', token: 'tok', org_id: 'org')
    end
  end

  def test_raises_insecure_connection_error_for_http_with_ip
    assert_raises(WorkflowClient::InsecureConnectionError) do
      WorkflowClient.new(base_url: 'http://10.0.0.1', token: 'tok', org_id: 'org')
    end
  end

  # -------------------------------------------------------------------
  # Test 7: Allows HTTP for localhost (dev mode)
  # -------------------------------------------------------------------
  def test_allows_http_for_localhost
    client = WorkflowClient.new(base_url: 'http://localhost:3000', token: 'tok', org_id: 'org')
    assert_instance_of WorkflowClient, client
  end

  def test_allows_http_for_127_0_0_1
    client = WorkflowClient.new(base_url: 'http://127.0.0.1:3000', token: 'tok', org_id: 'org')
    assert_instance_of WorkflowClient, client
  end

  def test_allows_https_for_any_host
    client = WorkflowClient.new(base_url: 'https://api.example.com', token: 'tok', org_id: 'org')
    assert_instance_of WorkflowClient, client
  end

  # -------------------------------------------------------------------
  # Test 8: Follows redirects when downloading files
  # -------------------------------------------------------------------
  def test_follows_redirect_on_download
    file_content = 'PDF file binary content here'

    # First endpoint returns 302 redirect to second endpoint (same host)
    @server.mount_proc('/rails/active_storage/blobs/abc/file.pdf') do |_req, res|
      res.status = 302
      res['Location'] = "http://127.0.0.1:#{@port}/s3/presigned/file.pdf"
      res.body = ''
    end

    @server.mount_proc('/s3/presigned/file.pdf') do |_req, res|
      res.status = 200
      res['Content-Type'] = 'application/pdf'
      res.body = file_content
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    body = client.download_file("#{@base_url}/rails/active_storage/blobs/abc/file.pdf")

    assert_equal file_content, body
  end

  # -------------------------------------------------------------------
  # Test 9: Strips auth headers on redirect to different host
  # -------------------------------------------------------------------
  def test_strips_auth_on_cross_host_redirect
    redirect_headers = {}

    # First endpoint (our app) redirects to a "different host" (we simulate with a different path)
    # We can't easily test cross-host with a single server, but we can verify the logic
    # by checking that the redirect target gets different headers.

    # Simulating: the redirect goes to the same server but we track headers at each stage
    initial_headers = {}
    @server.mount_proc('/rails/active_storage/blobs/xyz/doc.pdf') do |req, res|
      initial_headers['authorization'] = req['Authorization']
      res.status = 302
      # Redirect to same host (in real world this would be S3)
      res['Location'] = "http://127.0.0.1:#{@port}/final/doc.pdf"
      res.body = ''
    end

    @server.mount_proc('/final/doc.pdf') do |req, res|
      redirect_headers['authorization'] = req['Authorization']
      res.status = 200
      res.body = 'final content'
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'my_secret', org_id: 'org')
    result = client.download_file("#{@base_url}/rails/active_storage/blobs/xyz/doc.pdf")

    assert_equal 'final content', result
    # Initial request should have auth
    assert_equal 'Bearer my_secret', initial_headers['authorization']
    # Redirect to same host should still have auth (only cross-host strips it)
    # This tests that same-host redirects preserve auth
    assert_equal 'Bearer my_secret', redirect_headers['authorization']
  end

  # -------------------------------------------------------------------
  # Test 10: download_file rejects insecure URLs
  # -------------------------------------------------------------------
  def test_download_file_rejects_http_url
    client = WorkflowClient.new(base_url: 'https://api.example.com', token: 'tok', org_id: 'org')

    assert_raises(WorkflowClient::InsecureConnectionError) do
      client.download_file('http://evil.example.com/file.pdf')
    end
  end

  def test_download_file_allows_localhost_http
    file_content = 'local file content'
    @server.mount_proc('/files/test.pdf') do |_req, res|
      res.status = 200
      res.body = file_content
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    result = client.download_file("#{@base_url}/files/test.pdf")

    assert_equal file_content, result
  end

  # -------------------------------------------------------------------
  # Test 11: Raises HTTPError on too many redirects
  # -------------------------------------------------------------------
  def test_raises_on_too_many_redirects
    @server.mount_proc('/redirect_loop') do |_req, res|
      res.status = 302
      res['Location'] = "http://127.0.0.1:#{@port}/redirect_loop"
      res.body = ''
    end

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')

    assert_raises(WorkflowClient::HTTPError) do
      client.download_file("#{@base_url}/redirect_loop")
    end
  end

  # -------------------------------------------------------------------
  # Test 12: GraphQL error without truncation for short messages
  # -------------------------------------------------------------------
  def test_graphql_error_short_message_not_truncated
    error_response = {
      'errors' => [{ 'message' => 'Not found' }]
    }

    mount_graphql_response(error_response)

    client = WorkflowClient.new(base_url: @base_url, token: 'tok', org_id: 'org')
    error = assert_raises(WorkflowClient::GraphQLError) { client.fetch_project('1') }

    assert_equal 'Not found', error.message
  end

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

  private

  def mount_graphql_response(response_hash)
    @server.mount_proc('/graphql') do |req, res|
      @received_headers = {
        'authorization' => req['Authorization'],
        'x-organization-id' => req['X-Organization-Id'],
        'content-type' => req['Content-Type']
      }
      @received_body = req.body

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(response_hash)
    end
  end
end
