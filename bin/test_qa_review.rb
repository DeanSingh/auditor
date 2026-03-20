#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'json'
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
