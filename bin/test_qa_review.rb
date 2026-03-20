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
