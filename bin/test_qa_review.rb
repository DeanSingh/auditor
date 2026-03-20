#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'json'
require 'webrick'
require 'open3'
require_relative '../lib/workflow_client'
require_relative '../lib/qa_reviewer'

class TestQAReviewerDOS < Minitest::Test
  def test_dos_source_matches_letter_no_flag
    letter = { 'date' => 'January 15, 2021', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, date: 'January 15, 2021')]
    issues = QAReviewer.check_dos(letter, extracts)
    assert_empty issues
  end

  def test_dos_extract_differs_from_letter_flags_error
    letter = { 'date' => 'March 10, 2021', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, date: 'January 15, 2021')]
    issues = QAReviewer.check_dos(letter, extracts)
    assert_equal 1, issues.length
    assert_equal 'dos_verification', issues[0][:check]
    assert_equal 'error', issues[0][:severity]
    assert_includes issues[0][:message], 'January 15, 2021'
  end

  def test_dos_unknown_but_source_has_dos_flags_warning
    letter = { 'date' => 'Unknown', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    prompt = "<processed_content>\nDate of Service: 01/15/2021\nPatient seen for follow-up.\n</processed_content>"
    extracts = [make_extract(0, date: 'Unknown', prompt: prompt)]
    issues = QAReviewer.check_dos(letter, extracts)
    assert_equal 1, issues.length
    assert_equal 'warning', issues[0][:severity]
    assert_includes issues[0][:message], 'unknown date'
  end

  def test_dos_unknown_no_dos_in_source_no_flag
    letter = { 'date' => 'Unknown', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    prompt = "<processed_content>\nNo date information on this page.\n</processed_content>"
    extracts = [make_extract(0, date: 'Unknown', prompt: prompt)]
    issues = QAReviewer.check_dos(letter, extracts)
    assert_empty issues
  end

  def test_dos_iso_vs_human_readable_no_flag
    letter = { 'date' => '2021-01-15', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, date: 'January 15, 2021')]
    issues = QAReviewer.check_dos(letter, extracts)
    assert_empty issues
  end

  def test_dos_empty_extracts_no_flag
    letter = { 'date' => 'January 15, 2021', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    issues = QAReviewer.check_dos(letter, [])
    assert_empty issues
  end

  private

  def make_extract(iteration, date: 'Unknown', prompt: '<processed_content>No content</processed_content>')
    {
      'iteration' => iteration,
      'status' => 'SUCCEEDED',
      'result' => JSON.generate({ 'date' => date, 'provider' => 'Test Provider' }),
      'prompt' => prompt,
      'output' => '',
      'step' => { 'name' => 'Extract Info' }
    }
  end
end

class TestQAReviewerContentCoverage < Minitest::Test
  def test_content_present_in_summary_no_flag
    letter = {
      'date' => 'January 15, 2021',
      'pages' => [{ 'pageNumber' => 1 }],
      'content' => "# Header\n\nDiagnosis of lumbar disc herniation with radiculopathy noted."
    }
    extracts = [make_extract(0, result: { 'diagnosis' => 'Lumbar disc herniation with radiculopathy' })]
    issues = QAReviewer.check_content_coverage(letter, extracts)
    assert_empty issues
  end

  def test_content_missing_from_summary_flags_warning
    letter = {
      'date' => 'January 15, 2021',
      'pages' => [{ 'pageNumber' => 1 }],
      'content' => "# Header\n\nPatient seen for follow-up. No significant findings."
    }
    extracts = [make_extract(0, result: { 'diagnosis' => 'Lumbar disc herniation with radiculopathy' })]
    issues = QAReviewer.check_content_coverage(letter, extracts)
    assert_equal 1, issues.length
    assert_equal 'content_coverage', issues[0][:check]
    assert_equal 'warning', issues[0][:severity]
    assert_includes issues[0][:message], 'diagnosis'
  end

  def test_metadata_fields_skipped
    letter = {
      'date' => 'January 15, 2021',
      'pages' => [{ 'pageNumber' => 1 }],
      'content' => "# Header\n\nSome unrelated content here for testing."
    }
    extracts = [make_extract(0, result: {
      'date' => 'January 15, 2021',
      'provider' => 'J Smith, MD',
      'doc_category' => 'Medical Records that are very detailed and long'
    })]
    issues = QAReviewer.check_content_coverage(letter, extracts)
    assert_empty issues, "Metadata fields should not trigger content coverage checks"
  end

  def test_short_field_values_skipped
    letter = {
      'date' => 'January 15, 2021',
      'pages' => [{ 'pageNumber' => 1 }],
      'content' => "# Header\n\nContent."
    }
    extracts = [make_extract(0, result: { 'findings' => 'Normal' })]
    issues = QAReviewer.check_content_coverage(letter, extracts)
    assert_empty issues, "Short field values (< 20 chars) should be skipped"
  end

  def test_empty_extracts_no_flag
    letter = { 'date' => 'January 15, 2021', 'pages' => [{ 'pageNumber' => 1 }], 'content' => "# Header\n\nContent." }
    issues = QAReviewer.check_content_coverage(letter, [])
    assert_empty issues
  end

  private

  def make_extract(iteration, result: {})
    {
      'iteration' => iteration,
      'status' => 'SUCCEEDED',
      'result' => JSON.generate(result.merge('date' => result['date'] || 'Unknown', 'provider' => result['provider'] || 'Test')),
      'prompt' => '<processed_content>Page text</processed_content>',
      'output' => '',
      'step' => { 'name' => 'Extract Info' }
    }
  end
end

class TestQAReviewerProviderAvailability < Minitest::Test
  def test_unknown_provider_no_source_provider_flags_info
    letter = { 'provider' => 'Unknown', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, provider: 'Unknown')]
    issues = QAReviewer.check_provider_availability(letter, extracts)
    assert_equal 1, issues.length
    assert_equal 'provider_availability', issues[0][:check]
    assert_equal 'info', issues[0][:severity]
    assert_includes issues[0][:message], 'No provider name'
  end

  def test_unknown_provider_but_source_has_provider_no_flag
    letter = { 'provider' => 'Unknown', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, provider: 'Dr. J Smith')]
    issues = QAReviewer.check_provider_availability(letter, extracts)
    assert_empty issues
  end

  def test_nil_provider_no_source_flags_info
    letter = { 'provider' => nil, 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, provider: nil)]
    issues = QAReviewer.check_provider_availability(letter, extracts)
    assert_equal 1, issues.length
    assert_equal 'info', issues[0][:severity]
  end

  def test_valid_provider_no_flag
    letter = { 'provider' => 'J Smith, MD', 'pages' => [{ 'pageNumber' => 1 }], 'content' => 'x' }
    extracts = [make_extract(0, provider: 'J Smith, MD')]
    issues = QAReviewer.check_provider_availability(letter, extracts)
    assert_empty issues
  end

  private

  def make_extract(iteration, provider: 'Unknown')
    {
      'iteration' => iteration,
      'status' => 'SUCCEEDED',
      'result' => JSON.generate({ 'date' => 'January 15, 2021', 'provider' => provider }),
      'prompt' => '', 'output' => '',
      'step' => { 'name' => 'Extract Info' }
    }
  end
end

class TestQAReviewerRedundancy < Minitest::Test
  def test_overlapping_pages_flags_both
    letters = [
      { 'index' => 0, 'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }, { 'pageNumber' => 3 }],
        'provider' => 'A', 'content' => 'Unique content about anxiety disorder treatment plan.' },
      { 'index' => 1, 'pages' => [{ 'pageNumber' => 2 }, { 'pageNumber' => 3 }, { 'pageNumber' => 4 }],
        'provider' => 'B', 'content' => 'Different content about back pain management.' }
    ]
    findings = QAReviewer.check_redundancy(letters)
    assert findings.key?(0), "Letter 0 should be flagged"
    assert findings.key?(1), "Letter 1 should be flagged"
    assert_equal 'redundancy', findings[0].first[:check]
  end

  def test_no_overlap_different_content_no_flag
    letters = [
      { 'index' => 0, 'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }],
        'provider' => 'A', 'content' => 'Unique content about anxiety disorder treatment plan and medications.' },
      { 'index' => 1, 'pages' => [{ 'pageNumber' => 5 }, { 'pageNumber' => 6 }],
        'provider' => 'B', 'content' => 'Completely different content about orthopedic surgery and recovery.' }
    ]
    findings = QAReviewer.check_redundancy(letters)
    assert_empty findings
  end

  def test_high_similarity_no_page_overlap_flags_both
    shared = "Patient presents with chronic low back pain radiating to left lower extremity. " * 10
    letters = [
      { 'index' => 0, 'pages' => [{ 'pageNumber' => 1 }], 'provider' => 'A', 'content' => shared },
      { 'index' => 1, 'pages' => [{ 'pageNumber' => 5 }], 'provider' => 'B', 'content' => shared }
    ]
    findings = QAReviewer.check_redundancy(letters)
    assert findings.key?(0)
    assert findings.key?(1)
  end

  def test_single_letter_no_flag
    letters = [
      { 'index' => 0, 'pages' => [{ 'pageNumber' => 1 }], 'provider' => 'A', 'content' => 'Content' }
    ]
    findings = QAReviewer.check_redundancy(letters)
    assert_empty findings
  end
end

class TestQAReviewCLI < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"
    @server_thread = Thread.new { @server.start }
    @script = File.expand_path('../qa_review.rb', __FILE__)
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  def test_cli_outputs_json
    mount_cli_responses
    out, status = run_script('100', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '100', result['run_id']
    assert result.key?('letters_reviewed')
    assert result.key?('summary')
    assert result.key?('findings')
  end

  def test_cli_compact_mode
    mount_cli_responses
    out, status = run_script('100', '--compact', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    refute result.key?('findings'), 'Compact mode should omit full findings list'
    assert result.key?('flagged_findings')
  end

  def test_cli_csv_format
    mount_cli_responses
    out, status = run_script('100', '--format', 'csv', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    lines = out.strip.split("\n")
    assert_equal 'Provider,Pages,Category,DOS,Issues / Notes,Status,Time (min)', lines.first
  end

  def test_cli_exits_with_error_when_no_args
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

  def mount_cli_responses
    org_response = {
      'data' => { 'organizations' => [{ 'id' => 'org_1', 'name' => 'Test Org', 'current' => true }] }
    }

    summary_response = {
      'data' => {
        'run' => {
          'id' => '100', 'status' => 'SUCCEEDED',
          'document' => { 'lettersCount' => 1, 'sourcePages' => { 'count' => 3 } },
          'documentable' => true,
          'workflow' => { 'name' => 'Record Review', 'steps' => [
            { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'PROMPT', 'priority' => 1 }
          ] },
          'executions' => [], 'stats' => {}
        }
      }
    }

    letters_response = {
      'data' => {
        'run' => {
          'document' => {
            'lettersCount' => 1,
            'letters' => [{
              'id' => '1', 'index' => 0, 'date' => 'January 15, 2021',
              'provider' => 'J Smith, PhD',
              'category' => ['Psych Records'],
              'subcategory' => ['Reports by Psychologists'],
              'pageCount' => 1,
              'pages' => [{ 'pageNumber' => 1 }],
              'content' => "# Header\n\nSummary content here."
            }]
          }
        }
      }
    }

    extract_info_response = {
      'data' => {
        'run' => {
          'executions' => [{
            'iteration' => 0, 'status' => 'SUCCEEDED',
            'result' => JSON.generate({ 'date' => 'January 15, 2021', 'provider' => 'J Smith, PhD' }),
            'prompt' => '<processed_content>Page text</processed_content>',
            'output' => '', 'step' => { 'name' => 'Extract Info' },
            'started' => nil, 'finished' => nil
          }]
        }
      }
    }

    @server.mount_proc('/graphql') do |req, res|
      body = JSON.parse(req.body)
      query = body['query']

      result = if query.include?('organizations')
        org_response
      elsif query.include?('ExecutionFilterInput')
        extract_info_response
      elsif query.include?('content')
        letters_response
      else
        summary_response
      end

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(result)
    end
  end
end

class TestQAReviewerEngine < Minitest::Test
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

  def test_review_document_first_run
    mount_responses(
      run_summary: {
        'id' => '100', 'status' => 'SUCCEEDED',
        'document' => { 'lettersCount' => 2, 'sourcePages' => { 'count' => 5 } },
        'documentable' => true,
        'workflow' => { 'name' => 'Record Review', 'steps' => [
          { 'id' => '1', 'name' => 'Extract Info', 'kind' => 'PROMPT', 'priority' => 1 }
        ] },
        'executions' => [], 'stats' => {}
      },
      letters: [
        { 'id' => '1', 'index' => 0, 'date' => 'January 15, 2021',
          'provider' => 'J Smith, PhD', 'category' => ['Psych Records'],
          'subcategory' => ['Reports by Psychologists'],
          'pageCount' => 2, 'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }],
          'content' => "# Header\n\nPatient reports ongoing anxiety and depression." },
        { 'id' => '2', 'index' => 1, 'date' => 'Unknown',
          'provider' => nil, 'category' => ['Medical Records'],
          'subcategory' => ['Progress Notes'],
          'pageCount' => 1, 'pages' => [{ 'pageNumber' => 3 }],
          'content' => "# Header\n\nBrief note." }
      ],
      extract_info: [
        { 'iteration' => 0, 'status' => 'SUCCEEDED',
          'result' => JSON.generate({ 'date' => 'January 15, 2021', 'provider' => 'J Smith, PhD' }),
          'prompt' => '<processed_content>Patient seen on January 15 2021</processed_content>',
          'output' => '', 'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil },
        { 'iteration' => 1, 'status' => 'SUCCEEDED',
          'result' => JSON.generate({ 'date' => 'January 15, 2021', 'provider' => 'J Smith, PhD' }),
          'prompt' => '<processed_content>Continuation of previous note</processed_content>',
          'output' => '', 'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil },
        { 'iteration' => 2, 'status' => 'SUCCEEDED',
          'result' => JSON.generate({ 'date' => 'Unknown', 'provider' => nil }),
          'prompt' => '<processed_content>Date of Service: 03/01/2021\nProgress note.</processed_content>',
          'output' => '', 'step' => { 'name' => 'Extract Info' }, 'started' => nil, 'finished' => nil }
      ]
    )

    client = WorkflowClient.new(base_url: @base_url, token: 'test', org_id: 'org_1')
    reviewer = QAReviewer.new(client: client)
    result = reviewer.review('100')

    assert_equal '100', result['run_id']
    assert_equal 2, result['letters_reviewed']

    # Letter 2 should have findings: Unknown date but DOS available, no provider
    assert result['findings'].length >= 1, "Should have at least one flagged finding"
    letter2_finding = result['findings'].find { |f| f['pages'] == '3' }
    assert letter2_finding, "Letter 2 (page 3) should be flagged"
    checks = letter2_finding['issues'].map { |i| i['check'] }
    assert_includes checks, 'dos_verification', "Should flag DOS available in source: #{letter2_finding['issues']}"
    assert_includes checks, 'provider_availability', "Should flag missing provider: #{letter2_finding['issues']}"
  end

  private

  def mount_responses(run_summary:, letters:, extract_info:)
    summary_response = { 'data' => { 'run' => run_summary } }

    letters_response = {
      'data' => { 'run' => { 'document' => { 'lettersCount' => letters.length, 'letters' => letters } } }
    }

    extract_response = {
      'data' => { 'run' => { 'executions' => extract_info } }
    }

    @server.mount_proc('/graphql') do |req, res|
      body = JSON.parse(req.body)
      query = body['query']

      result = if query.include?('ExecutionFilterInput')
        extract_response
      elsif query.include?('content')
        letters_response
      else
        summary_response
      end

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(result)
    end
  end
end
