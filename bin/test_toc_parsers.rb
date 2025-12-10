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

  def test_stop_at_content_boundary
    text = "08/15/22\n67-70\nKosak Chiropractic\nCHIEF COMPLAINT: Patient presents with back pain\n"

    entries = TheirsTOCParser.parse_text(text)

    # Should stop parsing when it hits "CHIEF COMPLAINT:" (medical content)
    assert_equal 1, entries.length
    assert_equal "2022-08-15", entries[0][:date]
    assert_equal [67, 68, 69, 70], entries[0][:pages]
    # Header should NOT include the CHIEF COMPLAINT line
    refute_includes entries[0][:header], "CHIEF COMPLAINT"
  end

  def test_multi_line_pages_before_content
    text = <<~TEXT
      07/07/10
      103-
      105,
      249-251
      Sarbjot
      Kaur, MD –
      Kaiser
      Permanente
      Kaiser Permanente, Sarbjot Kaur, MD, Office Visit, 07/07/10
      HISTORY OF PRESENT ILLNESS: Patient is here with wife
    TEXT

    entries = TheirsTOCParser.parse_text(text)

    # Should collect ALL pages before stopping at HISTORY
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
    # Should NOT include HISTORY line
    refute_includes entries[0][:header], "HISTORY"
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
end

puts "Running TOC Parser Tests..."
