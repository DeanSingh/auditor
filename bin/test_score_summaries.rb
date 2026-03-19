#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'webrick'
require 'json'
require 'open3'
require_relative '../lib/workflow_client'
require_relative '../lib/summary_scorer'

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

class TestSummaryScorerRubrics < Minitest::Test
  def test_rubric_for_known_subcategory
    rubric = SummaryScorer::RUBRICS['Progress Notes and Reports by Treating Physicians']
    assert_equal :standard_clinical, rubric[:header_shape]
    assert_includes rubric[:required_sections], 'Subjective'
    assert_includes rubric[:required_sections], 'Assessment'
  end

  def test_rubric_for_imaging
    rubric = SummaryScorer::RUBRICS['Diagnostic Studies (X-rays/MRI)']
    assert_equal :imaging, rubric[:header_shape]
    assert_includes rubric[:required_sections], 'Findings'
    assert_includes rubric[:required_sections], 'Impression'
  end

  def test_rubric_for_qme
    rubric = SummaryScorer::RUBRICS['QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME']
    assert_equal :qme, rubric[:header_shape]
    assert_includes rubric[:required_sections], 'Impairment'
  end

  def test_default_rubric_for_unknown_subcategory
    rubric = SummaryScorer.rubric_for('Something Never Seen Before')
    assert_equal :standard_clinical, rubric[:header_shape]
  end

  def test_rubric_for_selects_primary_from_array
    rubric = SummaryScorer.rubric_for(['Progress Notes and Reports by Treating Physicians', 'Other'])
    assert_equal :standard_clinical, rubric[:header_shape]
  end
end

class TestSummaryScorerChecks < Minitest::Test
  # --- check_header_format ---
  def test_header_format_valid_standard_clinical
    content = "# [January 15, 2021, Medical Report - J Smith, PhD]{.underline}\n\n**Subjective:**\nPatient reports pain."
    issues = SummaryScorer.check_header_format(content, :standard_clinical)
    assert_empty issues
  end

  def test_header_format_missing_underline
    content = "# [January 15, 2021, Medical Report - J Smith, PhD]\n\nContent here."
    issues = SummaryScorer.check_header_format(content, :standard_clinical)
    assert_equal 1, issues.length
    assert_equal 'header_format', issues[0][:check]
    assert_includes issues[0][:message], 'underline'
  end

  def test_header_format_missing_heading_prefix
    content = "[January 15, 2021, Medical Report - J Smith]{.underline}\n\nContent."
    issues = SummaryScorer.check_header_format(content, :standard_clinical)
    assert_equal 1, issues.length
    assert_includes issues[0][:message], 'heading'
  end

  def test_header_format_cover_letter_no_underline_ok
    content = "# October 30, 2024, Cover Letter - B. Clark to Sarah Mitchell\n\nContent."
    issues = SummaryScorer.check_header_format(content, :cover_letter)
    assert_empty issues
  end

  def test_header_format_empty_content_skips
    issues = SummaryScorer.check_header_format('', :standard_clinical)
    assert_empty issues
  end

  # --- check_date_consistency ---
  def test_date_consistency_match
    content = "# [January 15, 2021, Medical Report - Provider]{.underline}\n\nContent."
    issues = SummaryScorer.check_date_consistency(content, 'January 15, 2021')
    assert_empty issues
  end

  def test_date_consistency_mismatch
    content = "# [March 10, 2021, Medical Report - Provider]{.underline}\n\nContent."
    issues = SummaryScorer.check_date_consistency(content, 'January 15, 2021')
    assert_equal 1, issues.length
    assert_equal 'date_consistency', issues[0][:check]
    assert_equal 'error', issues[0][:severity]
  end

  def test_date_consistency_unknown_expected
    content = "# [Unknown, Medical Report - Provider]{.underline}\n\nContent."
    issues = SummaryScorer.check_date_consistency(content, 'Unknown')
    assert_empty issues
  end

  def test_date_consistency_nil_date_skips
    content = "# [January 15, 2021, Medical Report - Provider]{.underline}\n\nContent."
    issues = SummaryScorer.check_date_consistency(content, nil)
    assert_empty issues
  end

  # --- check_provider_consistency ---
  def test_provider_consistency_match
    content = "# [January 15, 2021, Medical Report - J Smith, PhD]{.underline}\n\nContent."
    issues = SummaryScorer.check_provider_consistency(content, 'J Smith, PhD')
    assert_empty issues
  end

  def test_provider_consistency_mismatch
    content = "# [January 15, 2021, Medical Report - Wrong Doctor]{.underline}\n\nContent."
    issues = SummaryScorer.check_provider_consistency(content, 'J Smith, PhD')
    assert_equal 1, issues.length
    assert_equal 'provider_consistency', issues[0][:check]
  end

  def test_provider_consistency_partial_match
    content = "# [January 15, 2021, Medical Report - Smith]{.underline}\n\nContent."
    issues = SummaryScorer.check_provider_consistency(content, 'J Smith, PhD')
    assert_empty issues
  end

  def test_provider_consistency_multi_dash_header
    # Operative/letter/emergency headers have: Report - Provider - Facility
    # Provider is the second segment, not the facility
    content = "# [November 12, 2021, Operative Report - D Brown, MD - Cedar Sinai Los Angeles]{.underline}\n\nContent."
    issues = SummaryScorer.check_provider_consistency(content, 'D Brown, MD')
    assert_empty issues, "Should match provider in multi-dash header, not facility: #{issues}"
  end

  def test_provider_consistency_lab_header
    # Lab headers have: Report - Provider - Lab name
    content = "# [June 1, 2021, Laboratory Report - Quest Diagnostics - Main Lab]{.underline}\n\nContent."
    issues = SummaryScorer.check_provider_consistency(content, 'Quest Diagnostics')
    assert_empty issues
  end

  # --- check_empty_content ---
  def test_empty_content_multi_page_flagged
    issues = SummaryScorer.check_empty_content('', 3)
    assert_equal 1, issues.length
    assert_equal 'empty_content', issues[0][:check]
    assert_equal 'error', issues[0][:severity]
  end

  def test_empty_content_single_page_not_flagged
    issues = SummaryScorer.check_empty_content('', 1)
    assert_empty issues
  end

  def test_nonempty_content_ok
    issues = SummaryScorer.check_empty_content('Some content here', 5)
    assert_empty issues
  end

  # --- check_required_sections ---
  def test_required_sections_present
    content = "# Header\n\n**Subjective:**\nPain.\n\n**Assessment:**\nDiagnosis."
    issues = SummaryScorer.check_required_sections(content, %w[Subjective Assessment])
    assert_empty issues
  end

  def test_required_sections_missing
    content = "# Header\n\n**Subjective:**\nPain.\n\nTreatment plan."
    issues = SummaryScorer.check_required_sections(content, %w[Subjective Assessment])
    assert_equal 1, issues.length
    assert_equal 'required_sections', issues[0][:check]
    assert_equal 'warning', issues[0][:severity]
    assert_includes issues[0][:message], 'Assessment'
  end

  def test_required_sections_empty_list_ok
    issues = SummaryScorer.check_required_sections('Any content', [])
    assert_empty issues
  end

  # --- check_content_length ---
  def test_content_length_suspiciously_short
    content = "# Header\n\nShort."
    issues = SummaryScorer.check_content_length(content, 10)
    assert_equal 1, issues.length
    assert_equal 'content_length', issues[0][:check]
    assert_equal 'warning', issues[0][:severity]
  end

  def test_content_length_ok_for_single_page
    content = "# Header\n\nShort."
    issues = SummaryScorer.check_content_length(content, 1)
    assert_empty issues
  end

  def test_content_length_adequate
    content = "# Header\n\n" + ("Content line.\n" * 50)
    issues = SummaryScorer.check_content_length(content, 5)
    assert_empty issues
  end
end

class TestScoreSummariesCLI < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    @port = @server[:Port]
    @base_url = "http://127.0.0.1:#{@port}"
    @server_thread = Thread.new { @server.start }
    @script = File.expand_path('../score_summaries.rb', __FILE__)
  end

  def teardown
    @server.shutdown
    @server_thread.join(2)
  end

  def test_cli_outputs_scorecard_json
    mount_cli_responses

    out, status = run_script('100', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '100', result['run_id']
    assert result.key?('letters_scored')
    assert result.key?('summary')
    assert result.key?('flagged_letters')
  end

  def test_cli_compact_mode
    mount_cli_responses

    out, status = run_script('100', '--compact', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    refute result.key?('letters'), 'Compact mode should omit full letters list'
    assert result.key?('flagged_letters')
  end

  def test_cli_accepts_url
    mount_cli_responses

    out, status = run_script('https://workflow.ing/dashboard/runs/100', '--base-url', @base_url)
    assert status.success?, "Script failed: #{out}"

    result = JSON.parse(out)
    assert_equal '100', result['run_id']
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
          'workflow' => { 'name' => 'Record Review', 'steps' => [] },
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
              'subcategory' => ['Reports by Psychologists, Psychiatrists, Neuropsychologists'],
              'pageCount' => 3,
              'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }, { 'pageNumber' => 3 }],
              'content' => "# [January 15, 2021, Medical Report - J Smith, PhD]{.underline}\n\n**Subjective:**\nAnxiety.\n\n**Assessment:**\nGAD."
            }]
          }
        }
      }
    }

    @server.mount_proc('/graphql') do |req, res|
      body = JSON.parse(req.body)
      query = body['query']

      result = if query.include?('organizations')
        org_response
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

class TestSummaryScorerEngine < Minitest::Test
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

  def test_score_document_first_run
    mount_scoring_responses(
      run_summary: {
        'id' => '100', 'status' => 'SUCCEEDED',
        'document' => { 'lettersCount' => 2, 'sourcePages' => { 'count' => 10 } },
        'documentable' => true,
        'workflow' => { 'name' => 'Record Review', 'steps' => [] },
        'executions' => [], 'stats' => {}
      },
      letters: [
        { 'id' => '1', 'index' => 0, 'date' => 'January 15, 2021',
          'provider' => 'J Smith, PhD', 'category' => ['Psych Records'],
          'subcategory' => ['Reports by Psychologists, Psychiatrists, Neuropsychologists'],
          'pageCount' => 3, 'pages' => [{ 'pageNumber' => 1 }, { 'pageNumber' => 2 }, { 'pageNumber' => 3 }],
          'content' => "# [January 15, 2021, Medical Report - J Smith, PhD]{.underline}\n\n**Subjective:**\nPatient reports ongoing anxiety.\n\n**Assessment:**\nGAD with moderate severity." },
        { 'id' => '2', 'index' => 1, 'date' => 'March 10, 2021',
          'provider' => 'R Johnson, MD', 'category' => ['Medical Records'],
          'subcategory' => ['Progress Notes and Reports by Treating Physicians'],
          'pageCount' => 2, 'pages' => [{ 'pageNumber' => 4 }, { 'pageNumber' => 5 }],
          'content' => '' }
      ]
    )

    client = WorkflowClient.new(base_url: @base_url, token: 'test', org_id: 'org_1')
    scorer = SummaryScorer.new(client: client)
    result = scorer.score('100')

    assert_equal '100', result['run_id']
    assert_equal 2, result['letters_scored']

    letter1 = result['letters'].find { |l| l['index'] == 0 }
    assert letter1['passed'], "Letter 1 should pass: #{letter1['issues']}"

    letter2 = result['letters'].find { |l| l['index'] == 1 }
    refute letter2['passed'], 'Letter 2 should fail (empty content)'
    assert letter2['issues'].any? { |i| i['check'] == 'empty_content' }

    assert_equal 1, result['summary']['flagged']
  end

  def test_score_old_pipeline_run
    mount_scoring_responses(
      run_summary: {
        'id' => '200', 'status' => 'SUCCEEDED',
        'workflow' => { 'name' => 'Record Review', 'steps' => [
          { 'id' => '1', 'name' => 'Medical Summary', 'kind' => 'PROMPT', 'priority' => 1,
            'action' => { '__typename' => 'Action__Prompt', 'messages' => [] } }
        ] },
        'executions' => [
          { 'id' => '1', 'status' => 'SUCCEEDED', 'step' => { 'name' => 'Medical Summary' } }
        ],
        'stats' => {}
      },
      medical_summary_executions: [
        { 'iteration' => 0, 'status' => 'SUCCEEDED',
          'output' => "<content>\n# [February 1, 2021, Medical Report - A Lee, MD]{.underline}\n\n**Subjective:**\nBack pain.\n\n**Assessment:**\nLumbar strain.\n</content>",
          'result' => nil,
          'prompt' => "Date: February 1, 2021\nProvider: A Lee, MD\nPages category and sub-category:\n- Page: 1\n- Category: Medical Records\n- Sub-category: Progress Notes and Reports by Treating Physicians\nPages in document: 2\n<processed_content>Content here</processed_content>",
          'step' => { 'name' => 'Medical Summary' },
          'started' => nil, 'finished' => nil }
      ]
    )

    client = WorkflowClient.new(base_url: @base_url, token: 'test', org_id: 'org_1')
    scorer = SummaryScorer.new(client: client)
    result = scorer.score('200')

    assert_equal '200', result['run_id']
    assert_equal 1, result['letters_scored']

    letter = result['letters'].first
    assert_equal 'February 1, 2021', letter['date']
    assert_equal 'A Lee, MD', letter['provider']
    assert letter['passed']
  end

  private

  def mount_scoring_responses(run_summary:, letters: nil, medical_summary_executions: nil)
    org_response = {
      'data' => { 'organizations' => [{ 'id' => 'org_1', 'name' => 'Test Org', 'current' => true }] }
    }

    summary_response = { 'data' => { 'run' => run_summary } }

    letters_response = if letters
      { 'data' => { 'run' => { 'document' => { 'lettersCount' => letters.length, 'letters' => letters } } } }
    end

    executions_response = if medical_summary_executions
      { 'data' => { 'run' => { 'executions' => medical_summary_executions } } }
    end

    @server.mount_proc('/graphql') do |req, res|
      body = JSON.parse(req.body)
      query = body['query']

      result = if query.include?('organizations')
        org_response
      elsif query.include?('content') && letters_response
        letters_response
      elsif query.include?('ExecutionFilterInput') && executions_response
        executions_response
      else
        summary_response
      end

      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(result)
    end
  end
end
