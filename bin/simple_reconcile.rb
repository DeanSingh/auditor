#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'
require 'set'

# Shared utilities for TOC parsing
module TOCParserUtils
  def truncate_header(text, max_length = 150)
    return text if text.length <= max_length
    truncated = text[0...max_length]
    last_space = truncated.rindex(' ')
    last_space ? text[0...last_space] : truncated
  end

  def normalize_date(date_str)
    return "UNKNOWN" if date_str == "Undated" || date_str.nil? || date_str.empty?

    begin
      parts = date_str.split('/')
      month = parts[0].to_i
      day = parts[1].to_i
      year = parts[2].to_i

      year += 2000 if year < 100

      Date.new(year, month, day).strftime("%Y-%m-%d")
    rescue ArgumentError
      "UNKNOWN"
    end
  end

  def parse_page_numbers(pages_str)
    pages = []

    # First, handle split ranges: "253- 257" → "253-257"
    # Remove spaces around hyphens: "253 - 257" or "253- 257" or "253 -257" → "253-257"
    cleaned = pages_str.gsub(/\s*-\s*/, '-')

    cleaned.split(',').each do |part|
      part = part.strip
      if part.match?(/^(\d+)-(\d+)$/)
        match = part.match(/^(\d+)-(\d+)$/)
        start_page = match[1].to_i
        end_page = match[2].to_i
        (start_page..end_page).each { |p| pages << p }
      elsif part.match?(/^\d+$/)
        pages << part.to_i
      end
    end

    pages.uniq.sort
  end
end

# Parse TOC entries from your indexed document (extracted text or docx)
class YoursTOCParser
  extend TOCParserUtils

  MONTH_MAP = {
    'january' => 1, 'february' => 2, 'march' => 3, 'april' => 4,
    'may' => 5, 'june' => 6, 'july' => 7, 'august' => 8,
    'september' => 9, 'october' => 10, 'november' => 11, 'december' => 12
  }.freeze

  MONTH_NAMES = MONTH_MAP.keys.join('|').freeze
  FULL_MONTH_PATTERN = /^\|\s*(#{MONTH_NAMES})\s+(\d{1,2}),\s+(\d{4})\s*\|/i.freeze

  def self.parse(file_path, case_dir: nil)
    content = extract_text(file_path, case_dir: case_dir)
    parse_text(content)
  end

  def self.parse_text(content)
    entries = []
    lines = content.split("\n")

    i = 0
    while i < lines.length
      line = lines[i]

      # Pattern: Full written date on single line
      # Example: "| September 28, 2023 | ..."
      if (match = line.match(FULL_MONTH_PATTERN))
        month = MONTH_MAP[match[1].downcase]
        date_str = "#{month}/#{match[2]}/#{match[3]}"
        add_entry(entries, lines, i, 0, date_str)
      # Pattern: Month name split across 4 lines
      # Example: "| Sept |" + "| ember |" + "| 28, |" + "| 2023 |"
      elsif line.match?(/^\|\s*[A-Za-z]{3,5}\s*\|/)
        parsed = try_parse_split_month(lines, i)
        if parsed
          date_str = "#{parsed[:month]}/#{parsed[:day]}/#{parsed[:year]}"
          add_entry(entries, lines, i, 3, date_str)
        end
      # Pattern: ISO date split across lines - YYYY- on line 1, MM-DD on line 2
      # Example: "| 2024- | ..." followed by "| 03-25 | ..."
      elsif (match = line.match(/^\|\s*(\d{4})-\s*\|/))
        year = match[1]

        # Check next line for MM-DD
        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        if (md_match = next_line.match(/^\|\s*(\d{2})-(\d{2})\s*\|/))
          month = md_match[1]
          day = md_match[2]
          date_str = "#{month}/#{day}/#{year}"

          add_entry(entries, lines, i, 1, date_str)
        end
      # Pattern: MM/DD on one line, /YYYY on next line
      # Example: "| 10/06 | ..." followed by "| /2025 | ..."
      elsif line.match?(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        match = line.match(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        month = match[1]
        day = match[2]

        # Check next line for year
        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        if next_line.match?(/^\|\s*\/(\d{2,4})\s*\|/)
          year = next_line.match(/^\|\s*\/(\d{2,4})\s*\|/)[1]
          date_str = "#{month}/#{day}/#{year}"

          add_entry(entries, lines, i, 1, date_str)
        end
      # Pattern: Split date - MM/ on line 1, DD on line 2, /YYYY on line 3
      elsif line.match?(/^\|\s*(\d{1,2})\/\s*\|/)
        match = line.match(/^\|\s*(\d{1,2})\/\s*\|/)
        month = match[1]

        # Get day from next line
        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        if next_line.match?(/^\|\s*(\d{1,2})\s*\|/)
          day = next_line.match(/^\|\s*(\d{1,2})\s*\|/)[1]

          # Get year from line after that
          year_line = i + 2 < lines.length ? lines[i + 2] : ""
          if year_line.match?(/^\|\s*\/(\d{2,4})\s*\|/)
            year = year_line.match(/^\|\s*\/(\d{2,4})\s*\|/)[1]
            date_str = "#{month}/#{day}/#{year}"

            add_entry(entries, lines, i, 2, date_str)
          end
        end
      # Pattern: Unknown date entries
      elsif line.match?(/^\|\s*Un\s*\|/) || line.match?(/^\|\s*unknown\s*\|/i)
        add_entry(entries, lines, i, 0, "Unknown", date: "UNKNOWN")
      end

      i += 1
    end

    entries
  end

  private

  def self.try_parse_split_month(lines, start_idx)
    # Collect up to 4 lines and extract first cell content from each
    parts = []
    (0..3).each do |offset|
      line = lines[start_idx + offset] || ""
      if (m = line.match(/^\|\s*([^|]*?)\s*\|/))
        parts << m[1].strip
      else
        break
      end
    end

    return nil if parts.length < 4

    # Try to reassemble: "Sept" + "ember" = "September", "Oct" + "ober" = "October", etc.
    candidate_month = (parts[0] + parts[1]).downcase
    month_num = MONTH_MAP[candidate_month]
    return nil unless month_num

    # parts[2] should be day (with optional comma): "28," or "28"
    day_match = parts[2].match(/^(\d{1,2}),?$/)
    return nil unless day_match
    day = day_match[1].to_i

    # parts[3] should be year: "2023"
    year_match = parts[3].match(/^(\d{4})$/)
    return nil unless year_match
    year = year_match[1].to_i

    { month: month_num, day: day, year: year }
  end

  def self.add_entry(entries, lines, start_idx, skip_lines, date_str, date: nil)
    # Extract header and pages
    data = extract_entry_data(lines, start_idx, skip_lines)

    # Only add entry if it has pages (for Unknown dates)
    return if data[:page_nums].empty? && date == "UNKNOWN"

    # Use first(1) to avoid duplicate text from table cells
    header = data[:header_lines].first(1).join(" ").strip
    header = truncate_header(header)

    normalized_date = date || normalize_date(date_str)

    entries << {
      date: normalized_date,
      date_str: date_str,
      pages: data[:page_nums].uniq.sort,
      header: header
    }
  end

  def self.extract_entry_data(lines, start_idx, skip_lines)
    header_lines = []
    page_nums = []

    idx = start_idx
    while idx < lines.length
      l = lines[idx]

      # Stop at TOC entry separator
      break if l.match?(/^\+[-+]+\+/)

      # Stop at next date pattern (new entry) - but not current date block
      if idx > start_idx + skip_lines
        # Check for MM/DD pattern or MM/ pattern (start of new entry)
        break if l.match?(/^\|\s*\d{1,2}\//)
      end

      # Stop at "Unknown" date marker
      break if idx > start_idx + skip_lines && (l.match?(/^\|\s*Un\s*\|/) || l.match?(/^\|\s*unknown\s*\|/i))

      # Extract header text from 3rd column
      if l.match?(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)
        text = l.match(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)[1].strip
        header_lines << text unless text.empty?
      end

      # Extract page numbers from last column (supports ranges like "178-191")
      if l.match?(/\|\s*([\d,\s\-]+)\s*\|?\s*$/)
        pages_match = l.match(/\|\s*([\d,\s\-]+)\s*\|?\s*$/)
        page_nums.concat(parse_page_numbers(pages_match[1]))
      end

      idx += 1
    end

    { header_lines: header_lines, page_nums: page_nums }
  end

  def self.extract_text(file_path, case_dir: nil)
    ext = File.extname(file_path).downcase

    case ext
    when '.txt'
      File.read(file_path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    when '.docx'
      # Save extracted text to case folder if provided, otherwise same directory as source
      if case_dir
        basename = File.basename(file_path, '.*')
        output_file = File.join(case_dir, "reports", "#{basename}_toc_extracted.txt")
        # Always regenerate - YOUR docs can change during testing
        puts "  Converting #{File.basename(file_path)} to text..."
        system("pandoc", file_path, "-t", "plain", "-o", output_file)
      else
        output_file = file_path.gsub(/\.docx$/i, '_toc_extracted.txt')
        # Cache for non-case runs
        unless File.exist?(output_file)
          puts "  Converting #{File.basename(file_path)} to text..."
          system("pandoc", file_path, "-t", "plain", "-o", output_file)
        end
      end
      File.read(output_file, encoding: 'UTF-8', invalid: :replace, undef: :replace)
    else
      puts "Error: Unsupported format for yours: #{ext}"
      exit 1
    end
  end
end

# Parse TOC entries from vendor's indexed PDF
class TheirsTOCParser
  extend TOCParserUtils
  def self.parse(pdf_path)
    # ONLY parse first 25 pages - TOC should be at front of PDF
    text = `mutool draw -F txt "#{pdf_path}" 1-25 2>&1`.force_encoding('UTF-8')
    parse_text(text)
  end

  def self.parse_text(text)
    entries = []
    lines = text.split("\n")

    i = 0
    while i < lines.length
      line = lines[i].strip

      # Look for date pattern - but only process if it's a real TOC entry (has pages)
      if line.match?(/^(\d{1,2}\/\d{1,2}\/\d{2,4})$/)
        # Check if this is a real TOC entry or just a date in excerpt text
        unless is_toc_boundary?(lines, i)
          # Date in excerpt text - skip it
          i += 1
          next
        end

        date_str = line
        normalized = normalize_date(date_str)

        # Collect page numbers from multiple lines (they may be split)
        # Example: "208," on one line, "219-221" on next
        # Scan until boundary (next date, Undated, or EOF)
        # IMPORTANT: Stop collecting pages after first header line (prevents phone numbers/CPT codes)
        pages = []
        pages_lines = []
        header_lines = []
        found_header = false  # Track when we've moved past pages into header content

        idx = i + 1
        while idx < lines.length
          l = lines[idx].strip

          # Stop at next date or Undated (new entry starts)
          # But check if it's a real TOC entry (has pages) vs date in excerpt text
          if is_toc_boundary?(lines, idx)
            break
          elsif l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)
            # Date without pages - just excerpt text, treat as header
            header_lines << l if header_lines.length < 5
            found_header = true
            idx += 1
            next
          end
          break if l.match?(/^Undated$/)

          # Skip empty lines
          if l.empty?
            idx += 1
            next
          end

          # Skip lines that look like dates (contain slashes with digits)
          # This prevents "01/02/23 to 08/13/23" from being parsed as page "01"
          if l.match?(/\d+\/\d+/)
            # This is a date in content, not page numbers - treat as header
            header_lines << l
            found_header = true
            idx += 1
            next
          end

          # If line is entirely page numbers AND we haven't seen header yet, collect them
          # Only match lines that contain ONLY digits, hyphens, commas, and spaces
          if !found_header && l.match?(/^[\d\-,\s]+$/)
            pages_lines << l
          elsif l.match?(/^([\d\-,]+)([A-Z][a-z]+)/)
            # Handle concatenated case: "235-240Parveen"
            match = l.match(/^([\d\-,]+)([A-Z].*)/)
            pages_lines << match[1] unless found_header
            if header_lines.length < 5
              header_lines << match[2]
            end
            found_header = true
          else
            # Line is header text (provider name, etc) - stop collecting pages
            found_header = true
            if header_lines.length < 5
              header_lines << l
            end
          end

          idx += 1
        end

        # Parse all collected page number strings
        # Join with space to handle split ranges (e.g., "253-" + "257," → "253- 257,")
        combined_pages = pages_lines.join(" ")
        pages.concat(parse_page_numbers(combined_pages))
        # Reject invalid page numbers > 500 (catches CPT codes like 98940, addresses like 811/923)
        pages = pages.select { |p| p <= 500 }.uniq.sort

        # Only add entry if it has pages (skip invalid date-only entries from index lists)
        unless pages.empty?
          # Truncate header to reasonable length
          header = header_lines.join(" ")
          header = truncate_header(header)

          entries << {
            date: normalized,
            date_str: date_str,
            pages: pages,
            header: header
          }
        end

        # Jump to where inner loop stopped to avoid re-scanning consumed lines
        i = idx - 1  # -1 because loop will do i += 1 at the end
      elsif line.match?(/^Undated$/)
        normalized = "UNKNOWN"

        # Scan until boundary (next date, another Undated, or EOF)
        # IMPORTANT: Stop collecting pages after first header line (prevents phone numbers/CPT codes)
        pages = []
        pages_lines = []
        header_lines = []
        found_header = false  # Track when we've moved past pages into header content

        idx = i + 1
        while idx < lines.length
          l = lines[idx].strip

          # Stop at next date pattern (new entry) - check BEFORE processing
          # But check if it's a real TOC entry (has pages) vs date in excerpt text
          if is_toc_boundary?(lines, idx)
            break
          elsif l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)
            # Date without pages - just excerpt text, treat as header
            header_lines << l if header_lines.length < 5
            found_header = true
            idx += 1
            next
          end

          # Stop at another "Undated" marker (new entry)
          break if l.match?(/^Undated$/)

          # Skip empty lines
          if l.empty?
            idx += 1
            next
          end

          # Skip lines that look like dates (contain slashes with digits)
          # This prevents "01/02/23 to 08/13/23" from being parsed as page "01"
          if l.match?(/\d+\/\d+/)
            # This is a date in content, not page numbers - treat as header
            header_lines << l
            found_header = true
            idx += 1
            next
          end

          # If line is entirely page numbers AND we haven't seen header yet, collect them
          # Only match lines that contain ONLY digits, hyphens, commas, and spaces
          if !found_header && l.match?(/^[\d\-,\s]+$/)
            pages_lines << l
          elsif l.match?(/^([\d\-,]+)([A-Z][a-z]+)/)
            # Handle concatenated case: "235-240Parveen"
            match = l.match(/^([\d\-,]+)([A-Z].*)/)
            pages_lines << match[1] unless found_header
            if header_lines.length < 5
              header_lines << match[2]
            end
            found_header = true
          else
            # Line has no page numbers - collect as provider text (stop collecting pages)
            found_header = true
            if header_lines.length < 5
              header_lines << l
            end
          end

          idx += 1
        end

        # Parse all collected page number strings
        # Join with space to handle split ranges (e.g., "253-" + "257," → "253- 257,")
        combined_pages = pages_lines.join(" ")
        pages.concat(parse_page_numbers(combined_pages))
        # Reject invalid page numbers > 500 (catches CPT codes like 98940, addresses like 811/923)
        pages = pages.select { |p| p <= 500 }.uniq.sort

        # Only add entry if it has pages (skip invalid entries)
        unless pages.empty?
          # Truncate header to reasonable length
          header = header_lines.join(" ")
          header = truncate_header(header)

          entries << {
            date: normalized,
            date_str: "Undated",
            pages: pages,
            header: header
          }
        end

        # Jump to where inner loop stopped to avoid re-scanning consumed lines
        i = idx - 1  # -1 because loop will do i += 1 at the end
      end

      i += 1
    end

    entries
  end

  private

  def self.is_toc_boundary?(lines, idx)
    # Check if this line is a real TOC entry boundary (date followed by pages)
    # vs just a date in excerpt text
    l = lines[idx].strip

    # Check for date pattern
    return false unless l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)

    # Look ahead 2 lines for page numbers to confirm this is a real TOC entry
    next_1 = (idx + 1 < lines.length) ? lines[idx + 1].strip : ""
    next_2 = (idx + 2 < lines.length) ? lines[idx + 2].strip : ""

    # Has pages if either next line starts with page numbers
    next_1.match?(/^[\d\-,\s]+/) || next_2.match?(/^[\d\-,\s]+/)
  end
end

# Compare TOC entries and generate reconciliation data
class TOCComparator
  def self.compare(yours_entries, theirs_entries)
    yours_by_date = yours_entries.group_by { |e| e[:date] }
    theirs_by_date = theirs_entries.group_by { |e| e[:date] }

    all_dates = (yours_by_date.keys + theirs_by_date.keys).uniq.sort

    yours_only = []
    theirs_only = []
    same_dates = []

    all_dates.each do |date|
      yours_list = yours_by_date[date] || []
      theirs_list = theirs_by_date[date] || []

      if !yours_list.empty? && theirs_list.empty?
        # Date only in yours
        yours_list.each do |entry|
          # Skip entries with no pages (invalid TOC entries)
          next if entry[:pages].nil? || entry[:pages].empty?

          yours_only << {
            date: entry[:date],
            pages: entry[:pages],
            header: entry[:header]
          }
        end
      elsif yours_list.empty? && !theirs_list.empty?
        # Date only in theirs
        theirs_list.each do |entry|
          # Skip entries with no pages (invalid TOC entries)
          next if entry[:pages].nil? || entry[:pages].empty?

          theirs_only << {
            date: entry[:date],
            pages: entry[:pages],
            header: entry[:header]
          }
        end
      else
        # Date exists in both - check if pages overlap
        matched_theirs = Set.new
        matched_yours = Set.new

        yours_list.each do |y_entry|
          theirs_list.each do |t_entry|
            # If pages overlap, both TOCs have the same date
            if (y_entry[:pages] & t_entry[:pages]).any?
              same_dates << {
                date: y_entry[:date],  # Same date in both
                your_pages: y_entry[:pages],
                their_pages: t_entry[:pages],
                your_header: y_entry[:header],
                their_header: t_entry[:header]
              }
              matched_theirs.add(t_entry.object_id)
              matched_yours.add(y_entry.object_id)
            end
          end
        end

        # Add non-overlapping THEIRS entries to theirs_only
        theirs_list.each do |t_entry|
          unless matched_theirs.include?(t_entry.object_id)
            next if t_entry[:pages].nil? || t_entry[:pages].empty?
            theirs_only << {
              date: t_entry[:date],
              pages: t_entry[:pages],
              header: t_entry[:header]
            }
          end
        end

        # Add non-overlapping YOURS entries to yours_only
        yours_list.each do |y_entry|
          unless matched_yours.include?(y_entry.object_id)
            next if y_entry[:pages].nil? || y_entry[:pages].empty?
            yours_only << {
              date: y_entry[:date],
              pages: y_entry[:pages],
              header: y_entry[:header]
            }
          end
        end
      end
    end

    {
      yours_only: yours_only,
      theirs_only: theirs_only,
      same_dates: same_dates
    }
  end
end

# Main execution
if __FILE__ == $0
  if ARGV.length != 3
    puts "Usage: #{$0} <case_dir> <your_indexed.docx|txt> <their_indexed.pdf>"
    puts "\nExample:"
    puts "  #{$0} ~/git/auditor/cases/Reyes_Isidro ~/Downloads/yours.docx ~/Downloads/theirs.pdf"
    exit 1
  end

  case_dir = ARGV[0]
  yours_input = ARGV[1]
  theirs_pdf = ARGV[2]

  unless File.exist?(yours_input)
    puts "Error: Your document not found: #{yours_input}"
    exit 1
  end

  unless File.exist?(theirs_pdf)
    puts "Error: Their PDF not found: #{theirs_pdf}"
    exit 1
  end

  puts "Parsing your TOC: #{File.basename(yours_input)}..."
  yours_entries = YoursTOCParser.parse(yours_input, case_dir: case_dir)
  puts "Found #{yours_entries.size} entries"

  puts "\nParsing vendor TOC: #{File.basename(theirs_pdf)}..."
  theirs_entries = TheirsTOCParser.parse(theirs_pdf)
  puts "Found #{theirs_entries.size} entries"

  puts "\nComparing TOCs..."
  results = TOCComparator.compare(yours_entries, theirs_entries)

  # Output JSON for Phase 4 to consume
  json_path = File.join(case_dir, "reports", "reconciliation_data.json")
  File.write(json_path, JSON.pretty_generate(results))

  puts "\nResults:"
  puts "  Yours only: #{results[:yours_only].size}"
  puts "  Theirs only: #{results[:theirs_only].size}"
  puts "  Same dates: #{results[:same_dates].size}"
  puts "\nReconciliation data saved to: #{json_path}"
end
