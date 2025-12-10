#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'simple_reconcile'

class TestTheirsTOCParser < Minitest::Test
  def test_valid_single_line_entry
    text = "07/07/10\n103-105\nSarbjot Kaur, MD\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal "2010-07-07", entries[0][:date]
    assert_equal [103, 104, 105], entries[0][:pages]
    assert_equal "Sarbjot Kaur, MD", entries[0][:header]
  end

  def test_valid_multi_line_pages
    text = "07/21/18\n253-257,\n322-324\nParveen Kaur, MD\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal "2018-07-21", entries[0][:date]
    assert_equal [253, 254, 255, 256, 257, 322, 323, 324], entries[0][:pages]
    assert_equal "Parveen Kaur, MD", entries[0][:header]
  end

  def test_concatenated_pages_and_provider
    text = "06/30/17\n235-240Parveen\nKaur, MD\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal "2017-06-30", entries[0][:date]
    assert_equal [235, 236, 237, 238, 239, 240], entries[0][:pages]
    assert_equal "Parveen Kaur, MD", entries[0][:header]
  end

  def test_reject_invalid_page_numbers
    text = "08/15/22\n98940\nAdjustment\n"

    entries = TheirsTOCParser.parse_text(text)

    # Should reject entry because 98940 > 500
    assert_equal 0, entries.length
  end

  def test_reject_address_page_numbers
    text = "10/27/17\n811\nWHITE WING LN SUISUN CITY\n"

    entries = TheirsTOCParser.parse_text(text)

    # Should reject entry because 811 > 500
    assert_equal 0, entries.length
  end

  def test_billing_content_with_page_1
    text = "08/09/16\n1\nBilling Total: $102.00\n"

    entries = TheirsTOCParser.parse_text(text)

    # This creates a valid entry (page 1 with billing text as header)
    # The real-world fix is the 25-page limit prevents deep-PDF billing records
    assert_equal 1, entries.length
    assert_equal "2016-08-09", entries[0][:date]
    assert_equal [1], entries[0][:pages]
  end

  def test_multiple_entries
    text = "07/07/10\n103-105\nSarbjot Kaur, MD\n\n08/31/10\n110-113\nAnother Doctor\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 2, entries.length

    assert_equal "2010-07-07", entries[0][:date]
    assert_equal [103, 104, 105], entries[0][:pages]

    assert_equal "2010-08-31", entries[1][:date]
    assert_equal [110, 111, 112, 113], entries[1][:pages]
  end

  def test_undated_entry
    text = "Undated\n50-52\nUnknown Provider\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal "UNKNOWN", entries[0][:date]
    assert_equal [50, 51, 52], entries[0][:pages]
    assert_equal "Unknown Provider", entries[0][:header]
  end

  def test_collect_header_text
    text = "08/15/22\n67-70\nKosak Chiropractic\n"

    entries = TheirsTOCParser.parse_text(text)

    # Should collect pages and header text
    assert_equal 1, entries.length
    assert_equal "2022-08-15", entries[0][:date]
    assert_equal [67, 68, 69, 70], entries[0][:pages]
    assert_includes entries[0][:header], "Kosak Chiropractic"
  end

  def test_multi_line_split_ranges
    text = <<~TEXT
      07/07/10
      103-
      105,
      249-251
      Sarbjot
      Kaur, MD
    TEXT

    entries = TheirsTOCParser.parse_text(text)

    # Should collect ALL pages from split ranges
    assert_equal 1, entries.length
    assert_equal "2010-07-07", entries[0][:date]
    # Must include BOTH ranges: 103-105 AND 249-251
    assert_includes entries[0][:pages], 103
    assert_includes entries[0][:pages], 104
    assert_includes entries[0][:pages], 105
    assert_includes entries[0][:pages], 249
    assert_includes entries[0][:pages], 250
    assert_includes entries[0][:pages], 251
    assert_equal 6, entries[0][:pages].length
    # Should include provider name
    assert_includes entries[0][:header], "Sarbjot"
    assert_includes entries[0][:header], "Kaur"
  end

  def test_long_header_truncation
    # Create a very long header (over 150 chars)
    long_text = "After careful consideration of all available information, we are denying all liability for your claim of cumulative trauma injury for the period from 01/02/23 to 08/13/23"
    text = "09/28/23\n20\n#{long_text}\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal "2023-09-28", entries[0][:date]
    assert_equal [20], entries[0][:pages]
    # Header should be truncated to 151 chars (0..150)
    assert entries[0][:header].length <= 151, "Header should be truncated to max 151 chars, got #{entries[0][:header].length}"
    assert_includes entries[0][:header], "After careful consideration"
  end

  def test_date_in_content_not_parsed_as_page
    text = "09/28/23\n20-22\nDenial for period 01/02/23 to 08/13/23\n"

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 1, entries.length
    assert_equal [20, 21, 22], entries[0][:pages]  # NOT [1, 20, 21, 22]
    refute_includes entries[0][:pages], 1, "Should not parse '01' from date as a page number"
  end

  def test_date_in_excerpt_not_boundary
    # Date appears twice: once in TOC column, once in excerpt column
    # The second occurrence should NOT be treated as a new TOC entry boundary
    text = <<~TEXT
      03/12/24
      209-210
      Kaiser Permanente
      03/12/24
      Gave second dose
      03/25/24
      29-45
      Deposition
    TEXT

    entries = TheirsTOCParser.parse_text(text)

    assert_equal 2, entries.length, "Should parse both entries, not treat excerpt date as boundary"
    assert_equal "2024-03-12", entries[0][:date]
    assert_equal [209, 210], entries[0][:pages]
    assert_includes entries[0][:header], "Kaiser Permanente"
    assert_equal "2024-03-25", entries[1][:date]
    assert_equal (29..45).to_a, entries[1][:pages]
    assert_includes entries[1][:header], "Deposition"
  end
end

class TestYoursTOCParser < Minitest::Test
  def test_standard_entry
    content = <<~TABLE
      | 10/06 |          |                    |         |
      | /2025 |          |                    |         |
      |       |          | Cover Letter       |         |
      |       |          |                    | 1, 2, 3 |
      +-------+----------+--------------------+---------+
    TABLE

    entries = YoursTOCParser.parse_text(content)

    assert_equal 1, entries.length
    assert_equal "2025-10-06", entries[0][:date]
    assert_equal [1, 2, 3], entries[0][:pages]
    assert_includes entries[0][:header], "Cover Letter"
  end

  def test_unknown_date_entry
    content = <<~TABLE
      | Un    |          |                    |         |
      | known |          |                    |         |
      |       |          | Some Document      |         |
      |       |          |                    | 99      |
      +-------+----------+--------------------+---------+
    TABLE

    entries = YoursTOCParser.parse_text(content)

    assert_equal 1, entries.length
    assert_equal "UNKNOWN", entries[0][:date]
    assert_equal [99], entries[0][:pages]
  end

  def test_multiple_entries
    content = <<~TABLE
      | 01/03 |          |                    |         |
      | /2024 |          |                    |         |
      |       |          | Medical Report     |         |
      |       |          |                    | 178-191 |
      +-------+----------+--------------------+---------+
      | 01/04 |          |                    |         |
      | /2024 |          |                    |         |
      |       |          | Follow-up          |         |
      |       |          |                    | 192-194 |
      +-------+----------+--------------------+---------+
    TABLE

    entries = YoursTOCParser.parse_text(content)

    assert_equal 2, entries.length

    assert_equal "2024-01-03", entries[0][:date]
    assert_equal [178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191], entries[0][:pages]

    assert_equal "2024-01-04", entries[1][:date]
    assert_equal [192, 193, 194], entries[1][:pages]
  end

  def test_split_date_across_lines
    # Known issue: dates split across lines (08- on one line, 11 on next)
    # This test documents the current behavior
    content = <<~TABLE
      | 08/   |          |                    |         |
      | 11    |          |                    |         |
      | /2022 |          |                    |         |
      |       |          | Kosak Chiropractic |         |
      |       |          |                    | 67, 68  |
      +-------+----------+--------------------+---------+
    TABLE

    entries = YoursTOCParser.parse_text(content)

    # This test will fail if the split date bug exists
    # Expected: 1 entry with date "2022-08-11"
    # Current behavior: likely 0 entries (date pattern doesn't match)
    assert_equal 1, entries.length, "Should parse split date across lines"
    assert_equal "2022-08-11", entries[0][:date]
    assert_equal [67, 68], entries[0][:pages]
  end

  def test_iso_date_format_split_across_lines
    # ISO date format: YYYY- on line 1, MM-DD on line 2
    content = <<~TABLE
      | 2024- | Esquire | Videoconference    | 29, 30, |
      | 03-25 | Dep     | Deposition of      | 31, 32, |
      |       | osition | Jonathan Rosales   | 33, 34, |
      |       |         |                    | 35, 36, |
      |       |         |                    | 37, 38, |
      |       |         |                    | 39, 40, |
      |       |         |                    | 41, 43, |
      |       |         |                    | 44, 45  |
      +-------+---------+--------------------+---------+
    TABLE

    entries = YoursTOCParser.parse_text(content)

    assert_equal 1, entries.length, "Should parse ISO date format"
    assert_equal "2024-03-25", entries[0][:date]
    assert_equal [29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45], entries[0][:pages]
    assert_includes entries[0][:header], "Videoconference"
  end
end

puts "Running TOC Parser Tests..."
