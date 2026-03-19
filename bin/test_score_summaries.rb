#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'webrick'
require 'json'
require 'open3'
require_relative '../lib/workflow_client'

class TestWorkflowClientScoring < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"
    @server_thread = Thread.new { @server.start }
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  def test_fetch_run_document_letters_with_content
    letters = [
      { 'id' => '1', 'index' => 0, 'date' => 'January 15, 2021',
        'provider' => 'J Smith, PhD', 'category' => ['Psych Records'],
        'subcategory' => ['Reports by Psychologists, Psychiatrists, Neuropsychologists'],
        'pageCount' => 3, 'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }, { 'pageNumber' => 3 }],
        'content' => "# [January 15, 2021, Medical Report - J Smith, PhD]{.underline}\n\n**Subjective:**\nPatient reports..." }
    ]

    mount_response({
      'data' => {
        'run' => {
          'document' => {
            'lettersCount' => 1,
            'letters' => letters
          }
        }
      }
    })

    client = WorkflowClient.new(base_url: @base_url, token: 'test', org_id: 'org_1')
    result = client.fetch_run_document_letters_with_content('200')

    assert_equal 1, result.length
    assert_equal 'January 15, 2021', result[0]['date']
    assert_includes result[0]['content'], 'Medical Report - J Smith'
  end

  private

  def mount_response(response_hash)
    @server.mount_proc('/graphql') do |_req, res|
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(response_hash)
    end
  end
end
