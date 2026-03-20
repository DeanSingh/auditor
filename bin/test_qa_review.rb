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
