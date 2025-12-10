#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'
require 'set'

# Parse TOC entries from your indexed document (extracted text or docx)
class YoursTOCParser
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

      # Pattern: MM/DD on one line, /YYYY on next line
      # Example: "| 10/06 | ..." followed by "| /2025 | ..."
      if line.match?(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        match = line.match(/^\|\s*(\d{1,2})\/(\d{1,2})\s*\|/)
        month = match[1]
        day = match[2]

        # Check next line for year
        next_line = i + 1 < lines.length ? lines[i + 1] : ""
        if next_line.match?(/^\|\s*\/(\d{2,4})\s*\|/)
          year = next_line.match(/^\|\s*\/(\d{2,4})\s*\|/)[1]
          date_str = "#{month}/#{day}/#{year}"

          # Extract header and pages (MM/DD + /YYYY = skip 1 line)
          data = extract_entry_data(lines, i, 1)

          normalized_date = normalize_date(date_str)
          # Use first(1) to avoid duplicate text from table cells
          header = data[:header_lines].first(1).join(" ").strip
          header = truncate_header(header)

          entries << {
            date: normalized_date,
            date_str: date_str,
            pages: data[:page_nums].uniq.sort,
            header: header
          }
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

            # Extract header and pages (MM/ + DD + /YYYY = skip 2 lines)
            data = extract_entry_data(lines, i, 2)

            normalized_date = normalize_date(date_str)
            # Use first(1) to avoid duplicate text from table cells
            header = data[:header_lines].first(1).join(" ").strip
            header = truncate_header(header)

            entries << {
              date: normalized_date,
              date_str: date_str,
              pages: data[:page_nums].uniq.sort,
              header: header
            }
          end
        end
      # Pattern: Unknown date entries
      elsif line.match?(/^\|\s*Un\s*\|/) || line.match?(/^\|\s*unknown\s*\|/i)
        # Extract header and pages (Unknown = skip 0 lines)
        data = extract_entry_data(lines, i, 0)

        unless data[:page_nums].empty?
          # Use first(1) to avoid duplicate text from table cells
          header = data[:header_lines].first(1).join(" ").strip
          header = truncate_header(header)

          entries << {
            date: "UNKNOWN",
            date_str: "Unknown",
            pages: data[:page_nums].uniq.sort,
            header: header
          }
        end
      end

      i += 1
    end

    entries
  end

  private

  def self.truncate_header(text, max_length = 150)
    return text if text.length <= max_length
    truncated = text[0...max_length]
    last_space = truncated.rindex(' ')
    last_space ? text[0...last_space] : truncated
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
        # Parse ranges: "178-191" -> [178, 179, ..., 191]
        pages_match[1].split(',').each do |part|
          part = part.strip
          if part.match?(/^(\d+)-(\d+)$/)
            range_match = part.match(/^(\d+)-(\d+)$/)
            (range_match[1].to_i..range_match[2].to_i).each { |p| page_nums << p }
          elsif part.match?(/^\d+$/)
            page_nums << part.to_i
          end
        end
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

  def self.normalize_date(date_str)
    return "UNKNOWN" if date_str.nil? || date_str.empty?

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
end

# Parse TOC entries from vendor's indexed PDF
class TheirsTOCParser
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

      # Look for date pattern
      if line.match?(/^(\d{1,2}\/\d{1,2}\/\d{2,4})$/)
        date_str = line
        normalized = normalize_date(date_str)

        # Collect page numbers from multiple lines (they may be split)
        # Example: "208," on one line, "219-221" on next
        # Scan until boundary (next date, Undated, or EOF)
        pages = []
        pages_lines = []
        header_lines = []

        idx = i + 1
        while idx < lines.length
          l = lines[idx].strip

          # Stop at next date or Undated (new entry starts)
          break if l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)
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
            idx += 1
            next
          end

          # Stop collecting headers at content keywords
          break if l.match?(/^(HISTORY|SUBJECTIVE|OBJECTIVE|CHIEF|ASSESSMENT|PLAN|DIAGNOSIS|Patient (is|was|presents|complains|participated|reports))/i)

          # If line starts with page numbers, collect them
          if l.match?(/^[\d\-,\s]+/)
            page_part = l.match(/^([\d\-,\s]+)/)[1]
            pages_lines << page_part

            # Also grab any text after the pages on same line
            text_part = l.sub(/^[\d\-,\s]+/, '').strip
            unless text_part.empty?
              # Don't add if it's a content keyword
              break if text_part.match?(/^(HISTORY|SUBJECTIVE|OBJECTIVE|CHIEF|ASSESSMENT|PLAN|DIAGNOSIS|Patient (is|was|presents|complains|participated|reports))/i)
              header_lines << text_part
            end
          else
            # Line is header text (provider name, etc)
            header_lines << l
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
      elsif line.match?(/^Undated$/)
        normalized = "UNKNOWN"

        # Scan until boundary (next date, another Undated, or EOF)
        pages = []
        pages_lines = []
        header_lines = []

        idx = i + 1
        while idx < lines.length
          l = lines[idx].strip

          # Stop at next date pattern (new entry) - check BEFORE processing
          break if l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)

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
            idx += 1
            next
          end

          # Stop collecting headers at content keywords
          break if l.match?(/^(HISTORY|SUBJECTIVE|OBJECTIVE|CHIEF|ASSESSMENT|PLAN|DIAGNOSIS|Patient (is|was|presents|complains|participated|reports))/i)

          # Extract page numbers and provider text from line
          if l.match?(/^([\d\-,\s]+)/)
            # Extract pages: "235-240Parveen" -> "235-240"
            page_part = l.match(/^([\d\-,\s]+)/)[1]
            pages_lines << page_part

            # Extract provider text after pages: "235-240Parveen" -> "Parveen"
            text_part = l.sub(/^[\d\-,\s]+/, '').strip
            unless text_part.empty?
              # Don't add if it's a content keyword
              break if text_part.match?(/^(HISTORY|SUBJECTIVE|OBJECTIVE|CHIEF|ASSESSMENT|PLAN|DIAGNOSIS|Patient (is|was|presents|complains|participated|reports))/i)
              header_lines << text_part
            end
          else
            # Line has no page numbers - collect as provider text
            header_lines << l
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
      end

      i += 1
    end

    entries
  end

  private

  def self.truncate_header(text, max_length = 150)
    return text if text.length <= max_length
    truncated = text[0...max_length]
    last_space = truncated.rindex(' ')
    last_space ? text[0...last_space] : truncated
  end

  def self.parse_page_numbers(pages_str)
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

  def self.normalize_date(date_str)
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
