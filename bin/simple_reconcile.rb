#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'
require 'set'

# Parse TOC entries from your indexed document (extracted text or docx)
class YoursTOCParser
  def self.parse(file_path, case_dir: nil)
    entries = []
    content = extract_text(file_path, case_dir: case_dir)
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

          # Extract header text (3rd column) and page numbers (4th column)
          header_lines = []
          page_nums = []

          # Scan until boundary (next date, separator, or EOF)
          # Start from current line (i) which has MM/DD, continue through /YYYY line
          idx = i
          while idx < lines.length
            l = lines[idx]

            # Stop at TOC entry separator (marks end of current entry)
            break if l.match?(/^\+[-+]+\+/)

            # Stop at next date pattern (new entry) - but not the current line
            # Need to skip at least the /YYYY line (i+1)
            if idx > i + 1
              # Check for MM/DD pattern (start of new entry)
              break if l.match?(/^\|\s*\d{1,2}\/\d{1,2}\s*\|/)
            end

            # Stop at "Unknown" date marker (but not if we're on the current entry)
            break if idx > i + 1 && (l.match?(/^\|\s*Un\s*\|/) || l.match?(/^\|\s*unknown\s*\|/i))

            # Extract header text from 3rd column
            if l.match?(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)
              text = l.match(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)[1].strip
              header_lines << text unless text.empty?
            end

            # Extract page numbers from last column
            if l.match?(/\|\s*([\d,\s]+)\s*\|?\s*$/)
              pages_match = l.match(/\|\s*([\d,\s]+)\s*\|?\s*$/)
              page_nums.concat(pages_match[1].scan(/\d+/).map(&:to_i))
            end

            idx += 1
          end

          normalized_date = normalize_date(date_str)
          header = header_lines.first(3).join(" ").strip

          entries << {
            date: normalized_date,
            date_str: date_str,
            pages: page_nums.uniq.sort,
            header: header
          }
        end
      # Pattern: Unknown date entries
      elsif line.match?(/^\|\s*Un\s*\|/) || line.match?(/^\|\s*unknown\s*\|/i)
        # Scan until boundary to extract pages and headers
        header_lines = []
        page_nums = []

        idx = i
        while idx < lines.length
          l = lines[idx]

          # Stop at TOC entry separator
          break if l.match?(/^\+[-+]+\+/)

          # Stop at next date pattern (new entry)
          break if idx > i && (l.match?(/^\|\s*\d{1,2}\/\d{1,2}\s*\|/) || l.match?(/^\|\s*\/\d{2,4}\s*\|/))

          # Stop at another "Unknown" marker
          break if idx > i && (l.match?(/^\|\s*Un\s*\|/) || l.match?(/^\|\s*unknown\s*\|/i))

          # Extract header text from 3rd column
          if l.match?(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)
            text = l.match(/\|\s*[^|]*\|\s*[^|]*\|\s*([^|]+)\|/)[1].strip
            header_lines << text unless text.empty?
          end

          # Extract page numbers from last column
          if l.match?(/\|\s*([\d,\s]+)\s*\|?\s*$/)
            pages_match = l.match(/\|\s*([\d,\s]+)\s*\|?\s*$/)
            page_nums.concat(pages_match[1].scan(/\d+/).map(&:to_i))
          end

          idx += 1
        end

        unless page_nums.empty?
          entries << {
            date: "UNKNOWN",
            date_str: "Unknown",
            pages: page_nums.uniq.sort,
            header: header_lines.first(3).join(" ").strip
          }
        end
      end

      i += 1
    end

    entries
  end

  private

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
    entries = []
    text = `mutool draw -F txt "#{pdf_path}" 2>&1`.force_encoding('UTF-8')
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

          # Stop at next date pattern (new entry)
          break if l.match?(/^\d{1,2}\/\d{1,2}\/\d{2,4}$/)

          # Stop at "Undated" marker (new entry)
          break if l.match?(/^Undated$/i)

          # Skip empty lines
          if l.empty?
            idx += 1
            next
          end

          # Stop if we hit summary excerpt (medical content keywords or colon patterns)
          if l.match?(/^(SUBJECTIVE|OBJECTIVE|HISTORY|CHIEF|DIAGNOSIS|ASSESSMENT|TREATMENT|PLAN|DOI:|Patient (presents|complains|reports|states)|Received for)/i)
            break
          end
          # Stop if line contains summary pattern (colon followed by description)
          if l.match?(/:\s+[A-Z]/) || l.match?(/\.\s+[A-Z]/)
            break
          end

          # Determine what to do based on line content
          if l.match?(/^[\d\-,\s]+$/)
            # Line is ONLY page numbers (e.g., "253-257," or "322-324")
            pages_lines << l
          elsif l.match?(/^([\d\-,\s]+)(.+)$/)
            # Line has pages + text (e.g., "322-324 Parveen")
            page_part = l.match(/^([\d\-,\s]+)/)[1]
            text_part = l.sub(/^[\d\-,\s]+/, '').strip

            pages_lines << page_part
            unless text_part.empty?
              header_lines << text_part
            end
          else
            # Line is pure text (provider name/header)
            header_lines << l
          end

          idx += 1
        end

        # Parse all collected page number strings
        # Join with space to handle split ranges (e.g., "253-" + "257," → "253- 257,")
        combined_pages = pages_lines.join(" ")
        pages.concat(parse_page_numbers(combined_pages))
        pages = pages.uniq.sort

        # Only add entry if it has pages (skip invalid date-only entries from index lists)
        unless pages.empty?
          entries << {
            date: normalized,
            date_str: date_str,
            pages: pages,
            header: header_lines.join(" ")  # Join with space instead of comma
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

          # Extract page numbers and provider text from line
          if l.match?(/^([\d\-,\s]+)/)
            # Extract pages: "235-240Parveen" -> "235-240"
            page_part = l.match(/^([\d\-,\s]+)/)[1]
            pages_lines << page_part

            # Extract provider text after pages: "235-240Parveen" -> "Parveen"
            text_part = l.sub(/^[\d\-,\s]+/, '').strip
            unless text_part.empty?
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
        pages = pages.uniq.sort

        # Only add entry if it has pages (skip invalid entries)
        unless pages.empty?
          entries << {
            date: normalized,
            date_str: "Undated",
            pages: pages,
            header: header_lines.join(" ")  # Join with space instead of comma
          }
        end
      end

      i += 1
    end

    entries
  end

  private

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
